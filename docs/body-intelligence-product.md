# MotionOS Body Intelligence: product and visualization architecture

## North star

MotionOS should not feel like a sensor dashboard. It should feel like a persistent **movement twin**: a spatial, evidence-linked model of how a person moves, loads their body, interacts with equipment, and changes across sessions.

The body is the primary interface. Charts remain useful, but they become supporting evidence around a coherent physical model.

## Product navigation

The current product shell becomes:

1. **Observe** — live readiness, telemetry, and the next measurement.
2. **Capture** — guided sport and calibration protocols.
3. **Body** — the persistent movement twin and spatial interpretation layer.
4. **Sessions** — sealed evidence, review, comparisons, and longitudinal history.
5. **Devices** — sensor health, calibration, pairing, and data provenance.

This preserves the evidence-first M0 capture substrate while giving ordinary users a clear reason to return to the product between captures.

## The three truth levels

Every visual layer must expose its evidence status.

### Observed

Directly supported by a captured sensor stream.

Examples:
- Watch wrist acceleration and angular rate.
- Heart rate when Health access and samples are available.
- Camera frames and native timestamps.
- Pressure values from qualified bilateral insoles.
- Equipment IMU motion.

### Model-estimated

Derived from one or more observed sources through a documented model.

Examples:
- 3D pose from calibrated multiview video.
- Center-of-mass proxy from pose and a personalized body model.
- Board orientation from markers, vision, and equipment IMU fusion.
- Joint angles, segment velocities, and movement phases.
- Muscle involvement estimated from pose, task priors, biomechanics, and optional EMG calibration.

These overlays must remain visually distinct from direct measurements and expose model confidence.

### Unavailable

The product should say what evidence is missing rather than silently fabricate a value.

Examples:
- Center of pressure without a pressure sensor or force plate.
- Muscle activation without a validated estimation model or EMG.
- Joint loading without the required geometry, kinetics, and calibration.

## Body model layers

The 3D body should be composed from independently versioned layers rather than one opaque score.

### 1. Geometry

Persistent person-specific body representation.

Inputs:
- height and segment measurements;
- optional body scan;
- limb lengths and asymmetries;
- wearable placement;
- equipment contact geometry.

Outputs:
- canonical body coordinate system;
- segment dimensions;
- sensor-to-body transforms;
- personalized visualization mesh.

### 2. Kinematics

Where the body is and how it moves.

Inputs:
- iPhone / external cameras;
- Watch IMU;
- optional additional wearables.

Outputs:
- 3D joints;
- segment orientation;
- joint angles;
- velocities and accelerations;
- movement phases;
- repeatability and symmetry descriptors.

### 3. Balance and support

How the body remains supported over time.

Inputs:
- 3D pose;
- bilateral pressure sensors or force plate;
- board / equipment pose;
- personalized geometry.

Outputs:
- center-of-mass projection;
- center of pressure;
- support polygon;
- sway path;
- COM-COP relationship;
- recovery events;
- left/right load distribution.

COM estimates and COP measurements are intentionally separate concepts.

### 4. Muscle and tissue model

Which anatomical systems are likely contributing.

The first production version should be model-estimated, not presented as a direct physiological measurement.

Inputs:
- exercise / movement class;
- 3D pose and joint dynamics;
- body geometry;
- external load;
- optional EMG calibration.

Outputs:
- relative muscle-group involvement;
- contraction timing estimates;
- bilateral asymmetry descriptors;
- cumulative exposure by movement pattern.

An optional EMG path can progressively calibrate individual users without making EMG a requirement for the core product.

### 5. Physiology

Inputs:
- heart rate;
- HRV when valid;
- workout duration;
- optional future temperature / respiration streams.

Outputs:
- session physiology context;
- effort context;
- recovery context.

This layer should not be mixed into mechanical metrics unless the relationship is explicitly modeled.

### 6. Equipment interaction

Inputs:
- board, bike, ski, racquet, club, shoe, or other equipment sensors;
- camera-derived equipment pose;
- known equipment geometry.

Outputs:
- body-to-equipment transforms;
- loading / orientation context;
- contact events;
- technique-specific features.

### 7. Confidence and provenance

Every displayed metric should be able to answer:

- Which raw sources support this?
- Was it observed or inferred?
- Which model and calibration generated it?
- How uncertain is it?
- Is this session comparable to the previous one?

This should be available from the visualization itself, not buried in settings.

## 3D interaction model

The Body surface should support four global lenses.

### Movement

Show the body regions directly covered by sensors and animate measured or reconstructed motion. A Watch-only session should highlight the Watch-bearing wrist / forearm, not paint whole-body motion.

### Muscles

Show anatomy overlays with a visible provenance badge:
- **Task model** for exercise-prior-only estimates.
- **Pose model** when estimated from kinematics.
- **EMG calibrated** when validated against user-specific EMG.

Avoid unvalidated exact activation percentages.

### Balance

Render:
- body;
- support surface;
- support polygon;
- COM projection;
- COP path;
- equipment orientation;
- recovery events.

Until these streams exist, render a neutral reference reticle and explain what is missing.

### Sources

Let users see the measurement system wrapped around their body: Watch, phone camera, external camera, pressure, equipment sensors, and sync state. This makes data quality tangible.

## Visual design language

The product should feel calm and spatial rather than like a sports betting dashboard.

- Dark / material-friendly 3D stage inside a light or system-adaptive product shell.
- Restrained semantic colors.
- Green: directly observed / qualified.
- Orange: model-estimated.
- Yellow: incomplete / needs evidence.
- Purple / indigo: product navigation and neutral analysis.
- Red: active recording, destructive actions, or true capture failure only.
- Rounded cards remain, but the body stage becomes the dominant visual object.
- Use motion sparingly: rotation, trace playback, phase transitions, and subtle temporal trails should communicate information rather than decorate.

## Audience and positioning

### Initial wedge

**People who perform physical skills and want to understand movement across sports.**

Examples:
- board sports;
- cycling;
- climbing;
- strength / conditioning;
- running;
- racquet and field sports.

The first promise is not medical diagnosis. It is:

> Capture your movement once, then understand it through the same body model across every activity.

### Secondary users

Coaches, trainers, researchers, and eventually rehabilitation professionals can use the same evidence model with deeper views, annotations, exports, and protocol controls.

Medical or rehabilitation claims should only be introduced when the relevant measurements, models, validation, and regulatory boundaries support them.

## Platform strategy

MotionOS should have three surfaces that share one session schema.

### Consumer app

Fast capture, body visualization, session review, progress, and actionable explanations.

### Pro / researcher mode

Raw evidence access, synchronization diagnostics, calibration inspection, protocol authoring, uncertainty, and export.

### SDK / data contract

A stable multimodal session format for third-party sensors, algorithms, and sport-specific models.

The defensible asset is not one score or one sport. It is the longitudinal, provenance-rich mapping from heterogeneous sensors to a persistent personalized movement model.

## Implementation sequence

### B9A — Body Intelligence shell

- first-class Body tab;
- interactive native 3D body;
- Movement / Muscles / Balance / Sources lenses;
- evidence-state labeling;
- latest sealed run integration;
- no fabricated balance or muscle measurements.

### B9B — Session spatial replay

- convert synchronized Vision pose output into body-joint trajectories;
- time scrubber;
- ghost trail;
- Watch region overlay;
- board / equipment pose;
- source-confidence timeline.

### B9C — Balance qualification

- bilateral insole ingestion;
- calibrated foot-to-insole registration;
- COP and left/right load;
- pose-derived COM proxy;
- COM-COP visualization;
- Indo Board sway and recovery metrics;
- repeatability gates.

### B9D — Personalized anatomy

- body profile / scan mesh import;
- segment scaling;
- persistent wearable placement;
- asymmetry-aware geometry;
- USD / USDZ body asset pipeline.

### B9E — Muscle model

- exercise / movement priors;
- pose-conditioned muscle-group estimator;
- optional EMG calibration contract;
- provenance levels;
- validation benchmark against held-out sessions.

### B10 — Sport lenses

Build sport-specific interpretation on top of the shared movement twin rather than creating separate sensor apps.

Each sport lens defines:
- protocol;
- relevant body / equipment features;
- validated metrics;
- feedback vocabulary;
- comparable-session rules;
- uncertainty boundaries.

## Success criteria

The interface is successful when a new user can answer, without knowing anything about IMUs or synchronization:

1. What did I do?
2. What did MotionOS actually measure?
3. What happened to my body and equipment?
4. Which parts are estimates?
5. What changed from a comparable prior session?
6. What should I capture next to learn more?

And an expert can still drill all the way down to the raw evidence and model provenance.
