# MotionOS Fitness Persona v0

## Purpose

Fitness Persona is the longitudinal layer above MotionOS capture.

It is intentionally **not** a universal fitness score.

The first version answers a narrower set of questions:

- What evidence has MotionOS collected about this person?
- Which measurements have been repeated under comparable conditions?
- What is the person's own descriptive baseline?
- What changed relative to that baseline?
- Which parts of the physical profile remain unmeasured?
- Which claims are measured, derived, self-reported, or model-estimated?

The persona must remain inspectable back to sealed session evidence.

## Data flow

```
raw evidence
    |
    v
session summaries
    |
    v
PersonaSessionEvidence
    |
    v
comparable-context grouping
    |
    v
robust descriptive baselines
    |
    v
FitnessPersonaSnapshot
    |
    +--> player/profile UI
    +--> longitudinal comparisons
    +--> future social/player-card layer
    +--> exportable JSON
```

The current implementation never trains on raw video directly and never converts a single sensor metric into a skill score.

## Evidence domains

Fitness Persona v0 defines six domains:

| Domain | Meaning in v0 | Current state |
| --- | --- | --- |
| Movement | Repeated descriptive movement signals in standardized tasks | Watch RMS signals supported |
| Cardiovascular response | Recorded heart-rate response in comparable sessions | Mean recorded HR supported |
| Power | Standardized power-related measurement | Not implemented |
| Mobility | Calibrated range/movement-envelope measurement | Not implemented |
| Recovery | Longitudinal recovery context | Not implemented |
| Body | Stable calibrated body geometry | Contract exists; calibration not implemented |

A domain with no qualifying evidence stays **Not measured**.

## Evidence coverage is not ability

Coverage states describe only how much comparable evidence exists:

- `none`: no qualifying observation
- `single_session`: one qualifying session
- `repeated`: 2–4 qualifying sessions
- `longitudinal`: 5+ qualifying sessions

These labels must never be presented as high/low fitness.

For example:

```
Movement: Longitudinal
```

means MotionOS has repeated movement observations.

It does **not** mean movement skill is high.

## Comparable contexts

Longitudinal baselines are grouped by an exact comparison context:

```
sport | protocol | capture mode
```

MotionOS must not silently pool:

- different sports;
- different protocols;
- standardized and free-form sessions;
- materially different capture modes.

This is deliberately conservative.

A future validated normalization model can merge contexts explicitly, with its own version and provenance.

## Baseline statistics

For each metric/context group, MotionOS stores:

- sample count;
- median;
- median absolute deviation when repeat evidence exists;
- latest value;
- latest minus median;
- latest observation date;
- provenance;
- optional robust 30-day trend.

The trend uses a median pairwise-slope approach when at least three observations exist.

Direction is descriptive only.

A negative movement-RMS trend is not automatically labeled improvement.
A lower mean heart rate is not automatically labeled improved fitness.

Interpretation belongs to a separately validated sport/task model.

## Current metric adapter

The iPhone product-run adapter currently emits:

### Movement

- `watch.user_acceleration_rms_g`
- `watch.rotation_rate_rms_rad_s`

These are derived summaries of the sealed Apple Watch journal.

They are descriptive signatures of Watch motion, not whole-body control or balance scores.

### Cardiovascular response

- `watch.mean_heart_rate_bpm`

This is a session summary of recorded heart-rate samples.

It is not VO2 max, aerobic capacity, recovery status, or cardiovascular fitness.

### Camera evidence

Camera presence is tracked as source evidence, but it does not populate the Body domain.

Body becomes characterized only after MotionOS persists an explicit validated body-calibration result.

## Provenance

Every persona metric has a provenance class:

- `measured`
- `derived`
- `self_reported`
- `model_estimated`

Future UI should preserve this distinction.

A user should be able to tell the difference between:

```
Heart rate: measured sensor samples
Mean heart rate: derived summary
Perceived effort: self-reported
Estimated center of mass: model-estimated
```

## Personal Body Model

The shared package now defines `PersonalBodyModel v1`.

It stores stable geometry:

- standing height;
- shoulder width;
- hip width;
- torso length;
- left/right upper-arm length;
- left/right forearm length;
- left/right femur length;
- left/right tibia length.

Every parameter includes:

- value in meters;
- observation time;
- provenance;
- source identifier;
- optional uncertainty.

A body model is immutable once written.

Normal workouts do not mutate it.

A new guided body calibration creates a new model version.

Old sessions remain bound to the body-model version used for their analysis.

## Body geometry versus body state

These are separate systems.

### PersonalBodyModel

Slow-changing structural calibration:

```
bone/segment geometry
stable proportions
rig version
calibration uncertainty
```

### BodyStateTimeline

Future low-rate longitudinal context:

```
body mass
source-reported body fat
lean mass
resting HR
HRV
sleep
recovery context
```

A smart-scale reading must not silently reshape the persistent 3D avatar.

Body composition can inform trends, but geometry changes only through explicit recalibration or a separately validated morphology model.

## Storage

The current iPhone implementation writes:

```
Documents/
  MotionOSPersona/
    fitness-persona-v0.json
```

This file is intentionally compact and exportable.

It can survive independent lifecycle policies for large raw video.

The long-term storage hierarchy remains:

```
raw evidence
    -> retained/archive/delete policy

derived session summaries
    -> compact and reproducible

persona snapshots
    -> tiny longitudinal state
```

Deleting raw media must eventually be possible without deleting retained persona summaries, while the product clearly reports which original evidence is no longer locally available.

## Social semantics

Future player cards should expose:

- evidence coverage;
- verified achievements;
- sport/task-specific attributes;
- personal trajectory;
- provenance;
- uncertainty.

Avoid a single cross-human "fitness score".

Cross-person competition should use task-specific normalized rules with explicit measurement contracts.

Examples:

- a standardized five-minute aerobic challenge;
- a validated jump/power protocol;
- a repeated movement-control protocol;
- sport-specific skill challenges.

## Next measurement protocols

### Power v0

Candidate protocol:

1. stationary calibration;
2. 3–5 standardized countermovement jumps;
3. iPhone full-body Vision capture;
4. Watch wrist motion as secondary timing context;
5. reject attempts with incomplete body visibility.

First outputs should remain geometric/kinematic:

- flight-time proxy where reliably observable;
- jump-height estimate only after validation;
- takeoff/landing timing;
- repeatability.

Do not infer ground-reaction force without an appropriate measurement/model validation path.

### Mobility v0

Candidate protocol:

- guided shoulder elevation;
- squat depth;
- hip/knee/ankle pose envelope;
- controlled trunk rotation.

First outputs:

- observed joint-angle range;
- side-to-side differences;
- repeatability;
- camera confidence.

No diagnosis or injury-risk classification.

### Recovery context v0

Future HealthKit ingress can provide standardized low-rate context such as:

- resting heart rate;
- HRV;
- sleep summaries;
- recent workout history.

These observations should contextualize a session, not be used to diagnose readiness or health without separate validation.

## Engineering value

Fitness Persona is also a useful systems boundary.

The capture layer optimizes:

- sensor fidelity;
- local durability;
- power;
- latency;
- storage;
- interruption tolerance.

The persona layer optimizes:

- semantic compression;
- provenance;
- longitudinal comparability;
- uncertainty;
- user meaning.

This separation lets MotionOS investigate low-level wearable-system tradeoffs without coupling product identity to a particular sensor implementation.

## v0 merge gate

Fitness Persona v0 is ready to leave draft only when:

- all shared persona/body-model tests pass;
- iPhone build passes;
- existing physical-beta paths remain unaffected;
- Persona renders correctly with zero sessions;
- Persona renders correctly with one session;
- repeated comparable sessions form one baseline;
- different capture contexts remain separate;
- aborted sessions do not contribute;
- exported JSON reopens successfully;
- UI never labels evidence coverage as ability;
- no unimplemented domain displays a fabricated score.
