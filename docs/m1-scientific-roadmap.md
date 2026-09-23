# MotionOS M1 Scientific Roadmap

M1 begins only after MotionOS can preserve and synchronize real physical
evidence. Its purpose is not to add more sensors for their own sake. Its purpose
is to determine which aspects of athlete + equipment motion are actually
observable from the available modalities, quantify disagreement between those
modalities, and then learn field models that retain calibrated uncertainty.

## Starting point

M0 deliberately separates:
- raw evidence from derived quantities;
- device-local time from mapped reference time;
- software validation from physical qualification;
- camera teacher evidence from biomechanical ground truth.

M1 must preserve those boundaries.

The first M1 question is:

> Given synchronized video, personalized geometry, Watch IMU, equipment IMU,
> and bilateral foot pressure/IMU, what physical state can we estimate
> reproducibly, and what remains unobservable or ambiguous?

## Critical risks before modeling

### 1. No physical evidence yet

Software CI cannot identify:
- true sampling-rate behavior;
- clock discontinuities;
- mount slippage;
- camera blur/occlusion;
- pressure zero drift;
- sensor saturation;
- real wireless failure patterns.

Therefore no M1 performance claim should be made before the first M0 physical
sessions exist.

### 2. Teacher leakage

A video-derived teacher can be wrong while looking plausible.

Every teacher stream must retain:
- source video hash;
- model name/version;
- model weights hash;
- camera calibration reference;
- per-joint/per-variable confidence when available;
- exact source-frame PTS;
- missing-output events.

No teacher output may overwrite raw Vision or source video evidence.

### 3. Coordinate-frame ambiguity

Comparing an IMU vector to a camera-derived vector is meaningless until all
relevant transforms are explicit.

M1 needs versioned transforms for:
- camera -> world;
- device sensor -> body segment;
- equipment sensor -> equipment frame;
- body model -> declared anatomical/body frame.

Every derived metric must identify the transform chain used.

### 4. Per-frame body registration can hide model error

A free similarity fit on every moving frame may absorb pose-model scale error,
articulation mismatch, or camera bias.

For quantitative M1 work:
1. estimate subject/camera registration from designated calibration poses;
2. freeze parameters that should be physically constant;
3. evaluate later frames against the frozen calibration;
4. report residual and apparent scale drift instead of fitting it away.

Per-frame similarity fits may remain useful as diagnostic/visualization output,
but not as the sole quantitative reference.

### 5. Temporal leakage

Adjacent video/sensor windows are strongly autocorrelated.

Primary validation splits must be grouped by:
- repetition;
- run;
- day;
- sensor remount;
- camera view;
- speed/intensity;
- eventually subject and sport.

Random adjacent-frame/window splits are development diagnostics only.

## M1-A0: observability matrix

Before implementing fusion, define each desired latent variable and which
measurements constrain it.

Example:

| Latent quantity | Camera | Watch | feet | equipment | identifiable first? |
| --- | --- | --- | --- | --- | --- |
| wrist angular velocity | derived pose | gyro direct | no | no | yes |
| board angular velocity | board markers/pose | indirect | indirect | gyro direct | yes |
| left/right normal-load fraction | visual proxy | no | pressure direct | indirect | yes |
| foot contact timing | visual | weak | pressure direct | weak | yes |
| global body translation | calibrated multi-view | no | weak/drifting | no | camera-dependent |
| full joint torque | insufficient alone | insufficient | insufficient | insufficient | no |
| full 3D GRF | insufficient | insufficient | plantar normal force only | insufficient | no |

A variable should not enter the primary teacher state until its observation
model and failure modes are explicit.

## M1-A1: calibrated multi-camera geometry

Prefer two fixed cameras with substantially different views for measurement.

Capture and hash:
- source video;
- camera intrinsics/distortion;
- image dimensions;
- camera extrinsics;
- calibration-board definition;
- world-frame definition;
- calibration residuals;
- exact video PTS.

Use a metric calibration object such as ChArUco when practical.

A handheld/context camera may be recorded separately but must not silently
become the metric reference.

For equipment sports, attach rigid fiducials to the equipment where safe. This
creates an independent camera-derived equipment pose that can be compared with
the mounted equipment IMU.

## M1-A2: calibration campaign

### Common primitives

Run before sport-specific movement:
- quiet stance;
- A/T pose;
- left/right weight transfer;
- front/rear weight transfer;
- squat;
- heel raises;
- single-leg stance;
- step initiation/contact;
- isolated wrist/device rotations;
- deliberate synchronization choreography;
- slow/medium/fast repetitions.

### Longboard blocks

Then run:
- stance;
- pushes;
- straight glide;
- repeated left/right carves;
- braking;
- front/rear loading;
- foot repositioning;
- controlled stabilization perturbations.

Repeat key blocks after remounting and on separate days.

## M1-A3: cross-modal residual benchmark

Do not train a learned fusion model first.

Implement deterministic comparisons:

### Timing
- physical-landmark residual in ms;
- clock drift ppm;
- leave-one-landmark-out clock-fit error;
- start/middle/end residual trend.

### Camera geometry
- calibration reprojection error;
- multi-view triangulation disagreement;
- body-model residual using frozen calibration.

### IMU/video agreement
- segment angular velocity from video vs gyro after frame transformation;
- acceleration direction/magnitude agreement where numerical differentiation is
  stable enough;
- equipment marker pose derivative vs equipment gyro.

### Pressure/video agreement
- pressure contact onset vs visually inferred contact;
- bilateral load-fraction transition vs body/support shift;
- pressure CoP movement vs foot/support geometry when comparable.

### Robustness
Stratify all metrics by:
- occlusion;
- motion speed;
- distance to camera;
- lighting;
- pose confidence;
- sensor dropout;
- remount/day.

## M1-A4: offline teacher state

Only after deterministic residuals are understood, construct an offline teacher.

Preferred first implementation:
- nonlinear/state-space smoothing or factor-graph style fusion;
- kinematic/body-length constraints;
- explicit measurement noise;
- robust losses for bad observations;
- missing observations represented as missing, not imputed silently;
- posterior uncertainty for every derived quantity.

The teacher may use cameras because it exists only for calibration/evaluation.

## M1-A5: wearables-only student

Train a field model to reproduce selected teacher quantities without video.

Baselines must include:
- Watch only;
- feet only;
- equipment only;
- Watch + feet;
- Watch + equipment;
- feet + equipment;
- all wearables.

Report whether each modality provides incremental information.

Primary evaluation:
- held-out run;
- held-out day/remount;
- held-out intensity;
- sensor-dropout robustness.

Do not collapse the benchmark into one overall score.

## M1-A6: public-data preflight

Before relying only on bespoke data, validate M1 infrastructure on public
multimodal datasets where licensing permits.

Useful classes of data:
- synchronized multi-view video + IMU + optical motion-capture reference;
- synchronized RGB-D + smartwatch/phone IMU;
- sparse-IMU motion datasets.

The goal is not to claim public-dataset performance as MotionOS field
validation. It is to catch split leakage, metric bugs, transform mistakes, and
model-pipeline failures before expensive physical collection.

## M1-B: cross-sport transfer

Add sports for complementary observability, not just variety.

Suggested progression:
1. walking/running: periodic contact and clear gait events;
2. longboarding: athlete-equipment coupling and bilateral loading;
3. cycling/MTB: strong equipment coupling with changing terrain;
4. climbing: occlusion, non-periodic motion, asymmetric loading.

Evaluate:
- zero-shot transfer;
- small-calibration adaptation;
- full sport-specific calibration.

The representation is useful only if we can identify what transfers and what is
sport-specific.

## What not to claim

Until separately validated, MotionOS should not claim:
- laboratory-grade ground truth from markerless video;
- full-body pose from a single wrist sensor;
- full 3D ground-reaction force from plantar pressure;
- joint torque/power from the current sensor set;
- technique quality from kinematic similarity alone;
- injury risk from the current evidence stack.

## Recommended execution order

1. close P0/P1/P2/P5A real-device gates;
2. complete one reproducible M0-B5 longboard ride;
3. repeat a shortened run on another day/remount;
4. implement calibrated multi-camera/world-frame artifacts;
5. implement deterministic cross-modal residuals;
6. run a public-data preflight;
7. build the offline probabilistic teacher;
8. train wearable-only baselines and ablations;
9. add a second sport;
10. only then explore coaching/performance feedback.

The project should optimize for falsifiable measurement claims before feature
count.
