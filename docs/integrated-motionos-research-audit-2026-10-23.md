# MotionOS integrated scientific + engineering audit (2026-10-23)

Scope: source-inspected main plus open research PRs #137 and #138 and
the recording/capture quality lanes #129, #130, and #136. This is **not**
a substitute for an independent physical hardware audit or a review of all
historic PR diffs. Current default branch is still
`ea8250958b00cd05b2afc0e5af112a729b620ba6`.

## Overall verdict

MotionOS has unusually strong **evidence provenance contracts**, useful
simulation tests and a meaningful personalized multimodal research direction.
It does **not** have a fully qualified production recording-to-muscle-tracking
system. Our principal risk is not too little modeling innovation. It is
*unintegrated product paths and incomplete physical qualification*.

### Priority / severity matrix

| Priority | Finding | Current evidence | Closure before claims |
| --- | --- | --- | --- |
| P0 | Large unmerged PR backlog and dependent branches | 25+ open PRs including layered M0/M1, capture, athlete profile and sensors | Stage an explicit integration sequence; qualify *one* physical recording first |
| P0 | Watch/iPhone/Action 4 handshake is not yet proven on the target physical hardware | Swift simulator and CI builds, first-run procedures | Watch transfer receipt, first continuous original video, stop/recovery and complete manifest |
| P0 | Root-relative Vision and synchronized 2D tracking are not automatically metric world-coordinate 3D motion | Existing calibrated-rig contract, no actual field-qualified two-camera rig attached | Measured ChArUco intrinsics, fixed extrinsics, mount verification, source clocks, source PTS and reprojection receipts |
| P0 | Native Action 4 external video pose track has native PTS but no source-decoder frame sequence | `ExternalVideoPoseTrack.swift` and `Action4PoseTrackAnalyzer.swift` | Preserve exact source-frame index from AVAssetReader/decoder; don't fake by numbering sparse pose samples |
| P0 | Muscle visualization could be mistaken for measured muscle activation/force | Body movement API includes model-estimated muscle intensities | UI visibly separates measured pose, geometric proxy and **simulated anatomical demand**; no medical/force claims |
| P1 | Cross-camera association may consume unusable frames and allow pairwise timing spread | Source inspection of original #138 implementation | Mitigated on #138: only consume contributing frames; shared-joint matching; full tolerance-window search and all-camera conservative clock check |
| P1 | Detector-only frame coverage inflates completeness for clips with long occlusions or missing data | #138 previously counted surviving anchor pose frames only | Mitigated on #138: require original duration, start PTS, nominal pose-sampling interval, and minimum source sampling coverage |
| P1 | Sparse cameras / difficult poses can have low ray disagreement yet poorly conditioned depth | Current world geometry measures residuals/ray distances but does not produce per-joint parallax angle or covariance | Add a predeclared parallax/conditioning gate and independent reference comparison prior to metric-accuracy claims |
| P1 | Greedy nearest-frame association can lose feasible global matches in dense/asynchronous multi-camera streams | Current #138 is a deterministic local match, not an optimal assignment | Benchmark anchor-reversal consistency; consider bounded monotone global assignment on repeated captures |
| P1 | Anatomical labeling can swap sides during rapid rotation/occlusion | Single-person affirmation and per-joint detector labels are not anatomical ground truth | Review side swaps; test 180-degree turns; include side/identity swap QC and independent reference |
| P1 | Body model registration and limb-length constraints do not prove anthropometric accuracy | Profile/scan hashes and geometric residuals | Acquire independent lengths/scans; use left/right measurements without mirroring; report calibration uncertainty |
| P1 | Pose confidence is preserved but not weighted in triangulation | #138 retains per-camera confidence, world-geometry currently unweighted | Predeclare a confidence-to-observation-noise mapping; validate on held-out cross-view reprojection |
| P1 | Multiple outputs can be overwritten without noticing stale analysis | Existing derived output behavior | #138 refuses prior correspondence/audit outputs; expand controlled immutable versioning to other research artifacts |
| P2 | Large central orchestration modules complicate ownership/changes | Large `cli.py`, `IndoBoardSessionCoordinator.swift`, `CameraCapturePipeline.swift`, `world_geometry.py` | After first field qualification, extract bounded interfaces with parity tests; avoid a risky all-at-once refactor |
| P2 | Session metrics are easy to compare across unmatched mount/view/protocol days | Camera posture confidence/segment measures are observational | Comparison UI should require protocol/mount identity and expose coverage/confounding; stratify days/mounts |

## Four layers that must stay separate

1. **Sensor evidence:** original video, Watch journal, hashes, original timestamps.
2. **Geometric estimates:** source image pose, calibrated multi-view positions,
   kinematic angles and their residuals.
3. **Biomechanical model outputs:** independently fitted anatomy, inverse
   kinematics, estimated moments and *modeled* muscle-tendon states, each with
   explicit inputs and assumptions.
4. **Physical measurement / validation:** calibrated force and pressure,
   independent motion reference, optional EMG with its own limitations.

A result at layer 2 must not be displayed as physiological truth at layer 4.

## Implementation status

Completed in stacked research code (not main, not physically qualified):

- PR #137: `motionos.personalized-kinematics.v1`, asymmetric profile,
  per-frame geometric knee estimates, source traceability and TRC export.
- PR #137 follow-up: automatic named joint map from immutable
  correspondences, explicit model-proposed versus human-reviewed labels.
- PR #138: source-hash-verified multiview 2D pose association into the
  existing calibrated triangulator, uncertainty and coverage gates,
  and original-source audits.
- #138 audit improvements: unusable-frame non-consumption, pairwise
  temporal constraints, source-clip completeness accounting, detector
  confidence retention, refused derived-output clobbering.

**Unimplemented**: source decoder frame-sequence export for Action 4,
automatic rig/intrinsics qualification on physical devices, camera-specific
pose source artifact conversion, anatomical mesh camera compositor,
OpenSim IK optimizer bridge, contact force estimation, and physically validated
muscle force/activation estimates.

## Proposed integration sequence

**Gate 0: stable physical capture (no modeling dependent on it).**
Integrate and evaluate the narrowly scoped #129 evidence/provenance
correction, #130 recording guard/runbook and #136 postflight audit
against current main. Resolve overlapping docs and duplicate capture QA
rather than independently merging all pending alternatives.

**Gate 1: first frozen field artifact.**
Capture a natural 120-second Indo Board product protocol, preserve source
camera bytes, Watch session and operator evidence; run postflight audit.
Predeclare required coverage, source integrity, time gap thresholds and
failed-run acceptance rules. Do not relabel poor capture as a model problem.

**Gate 2: one calibrated rig.**
Use actual target cameras, a single metric ChArUco world frame, frozen
intrinsics/extrinsics, capture-time mount verification and per-camera clock
uncertainty. Add native decoded frame index to the iPhone/Action 4
pose exports and independently probe source media duration.
Only then execute #138 and downstream #137.

**Gate 3: measured kinematics reliability.**
Measure per-joint coverage, parallax/conditioning, reprojection and
limb-length residuals across static, shifting, squatting and turn trials.
Repeat on a held-out day with intentionally varied camera angles.
Compare against independent reference if high-quality motion claims
will be made.

**Gate 4: anatomy and force hypotheses.**
Connect a licensed, pinned OpenSim model with fit residuals. Only after
external load measurements and model validation explore muscle-tendon
forces, static optimization and anatomy video compositing. Keep every
predicted field visibly labeled.

## Minimum independent falsification protocol

- Corrupt one source video, pose track, rig or calibration SHA and verify
  downstream operations fail before producing derived outputs.
- Drop Watch mid-session, deny permissions, fill storage, stop camera
  early and test explicit recovery/retained evidence.
- Deliberately move one tripod after calibration and require a rig
  failure, not an impressive-looking 3D visualization.
- Introduce left/right swaps and a fast 180-degree turn, occlude a
  knee, perturb timestamps and reduce camera separation.
- Compare outputs to deliberately held-out or manually annotated
  reference frames; report unavailable metrics rather than values
  filled in from assumptions.
- Test one user's repeated sessions before inviting broader usage;
  collect explicit consent, deletion/export and access controls for
  identifiable movement/health-related recordings.

## Definition of done

For the first field pilot, **done** means a non-developer can complete
camera setup, record/stop/recover a session, inspect data completeness,
and play back their 2D annotated movements with explicit limitations.
Personalized metric 3D and muscular overlays remain **research** until
the separately described geometry, model and validation gates pass.

**Decision:** prioritize physical pilot and integration convergence over
new consumer-facing dashboards, broader sports, automated body
composition guesses, or force estimation from video alone.
