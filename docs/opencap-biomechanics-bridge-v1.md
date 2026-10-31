# MotionOS ↔ OpenCap musculoskeletal results bridge (V1)

Status: **offline importer only**. Not a validated muscle estimator or a 3D anatomy viewer.

## Boundaries

OpenCap's `opencap-processing` post-processes OpenCap sessions and can run
OpenSim/OpenSimAD kinematics and muscle-driven simulations. It is not a drop-in
inference model for arbitrary MotionOS single-camera video. Preserve the
original MotionOS camera timestamps, provenance, body calibration, and
qualification gates. Run heavy OpenSim/CasADi calculations in an isolated
offline environment, never as an iOS/Watch runtime dependency.

The source repository is Apache-2.0. Dependencies, models, datasets and
OpenCap hosted services can have their own license/terms.

## Implemented

`src/motionos/opencap_import.py` reads an **already-generated** OpenSim
`.mot` / `.sto` table. Preferred source: OpenCap/OpenSimAD's
`kinematics_activations_<trial>_<case>.mot`.

The importer checks standard `endheader` storage syntax, column count,
uniqueness, numeric finiteness, strictly increasing time, declared table
dimensions, activation bounds and file size. It preserves SHA-256 fingerprints,
all source channel names and time samples, writes a versioned
`motionos.opencap-simulation.v1` JSON bundle, and refuses to overwrite
previous output or input evidence.

Usage after **separately** running and checking OpenCap processing:

```sh
python -m motionos.opencap_import \
  ./OpenSimData/Dynamics/squat/kinematics_activations_squat_0.mot \
  ./private/squat-opencap-simulation.json \
  --model-name LaiUhlrich2022 --trial-name squat \
  --model-file ./OpenSimData/Model/LaiUhlrich2022_scaled.osim
```

The output is not a validated OpenCap trial: source-file integrity does not
prove provenance, solver convergence, correct model anatomy, camera calibration,
or physiological accuracy. The model name is an operator label. Model file
identity is hash bound only when `--model-file` is supplied.

The `/activation` channels may refer to *torque actuators* rather than muscles
in torque-driven simulations. V1 sets
`source.muscle_channel_identity_verified=false`; no downstream UI should
render muscle heat maps until a versioned, model-specific muscle channel
registry verifies identity. Missing activation channels remain missing.
Rotation units are based on the OpenSim `inDegrees` header; translational
unit provenance remains unverified until an explicit model mapping.

## Intended architecture

```text
Capture → calibrated 2+ camera video → qualified marker time series
        → OpenSim inverse kinematics + model scaling
        → OpenCap/OpenSim muscle-driven optimization (offline)
        → vetted model + convergence/solver/kinematic residual checks
        → source-bound motionos.opencap-simulation.v1
        → coordinate + anatomical muscle-name registry
        → synchronized body/ghost/heat-map viewer
        → within-user and matched-cohort comparisons
```

## Not yet implemented

1. OpenCap cloud authentication, proprietary/hosted API orchestration, or an
   automatic MotionOS video-to-OpenCap session converter.
2. Automatic OpenSim inverse kinematics or muscle-driven simulation.
3. Model-specific conversion from OpenSim coordinates to MotionOS frame,
   bone meshes, muscle fibers/tendons, force vectors, or 3D UI rendering.
4. Solver convergence / reserve-actuator checks, tracking residuals,
   biomechanical reference validation or real Indo Board qualification.
5. Injury-risk scores, fatigue ground truth, EMG, tissue stress or strain.

## Release criteria

1. Merge and physically qualify **MotionOS PRs #137 and #138** with real
   calibrated multiview footage and correct native frame identities.
2. Independently reproduce an authorized OpenCap example end to end.
3. Check solver convergence, kinematics tracking error, model scaling, contact
   realism, reserve actuator contributions and missing channels.
4. Provide coordinate frames and model-specific anatomy map; display provenance
   and confidence/quality **per metric**, with no global invented accuracy score.
5. Check within-user test/retest repeatability and lab reference comparisons,
   stratified by task, camera configuration, body geometry and joint.
6. Require consent, license review and participant-disjoint cohort splits
   before any population reference ranks are published.

Raw participant videos, personalized meshes and motion traces remain
restricted by `docs/privacy-data-governance.md`; no re-identifiable artifacts
or scraped video are automatically eligible for public release.
