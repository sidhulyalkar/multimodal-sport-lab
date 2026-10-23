# M3-A: personalized 3D kinematics and OpenSim handoff

## Scope

This is the **first code-backed offline biomechanics bridge**, not a claim that MotionOS
estimates muscle forces. It takes the existing M1-A1 calibrated multiview
triangulation output, anchors an explicit landmark-to-anatomical-joint map to the
unmodified geometry report, and produces:

- A versioned JSON marker timeline with source point IDs and gap/quality diagnostics.
- Estimated left/right knee flexion angles, when all three supporting joints pass
  geometry and individualized segment-length checks.
- An optional marker trajectory in OpenSim-compatible **TRC** text format, in meters.

This supports the next stage: modeling the skeleton and attaching **estimated**
muscle-tendon trajectories. M3-A does **not** perform OpenSim Inverse Kinematics
(IK). TRC markers do not uniquely determine joint coordinates, external forces,
individual muscle recruitment, or tissue strain.

## Dependencies

1. A *real* passing calibrated camera rig receipt, schema
   motionos.camera-rig-receipt.v1, from two or more cameras.
2. A source motionos.world-frame.v1 artifact with meters, +Y-up axes,
   gravity in -Y, and SHA-256 matching the rig and geometry report.
3. A motionos.multiview-geometry-report.v1 derived by the existing
   'motionos triangulate-multiview' command, whose rig and world hashes match.
4. A motionos.body-model.v2 with independent left/right segment measures.
   If it declares a source scan hash, provide the original artifact with
   --body-source-artifact or the command fails. Example-only models remain
   marked non-personalized even if plausible.
5. A motionos.kinematic-joint-map.v1, explicitly mapping geometry point IDs to
   anatomical joint names at exact reference timestamps, hash-bound to the
   unmodified multiview geometry report.

Neither root-relative iPhone Vision 3D nor uncalibrated Action 4 pose automatically
becomes metric world geometry.

## Joint mapping

The pose research adapter must produce a JSON object of the form:

    {
      "schema_version": "motionos.kinematic-joint-map.v1",
      "subject_id": "anonymous-participant-01",
      "geometry_report_sha256": "REPLACE_WITH_GEOMETRY_REPORT_SHA256",
      "frames": [
        {
          "reference_time_ns": 1740000000000,
          "joints": {
            "leftHip": "actual_report_point_id_for_left_hip",
            "leftKnee": "actual_report_point_id_for_left_knee",
            "leftAnkle": "actual_report_point_id_for_left_ankle",
            "rightHip": "actual_report_point_id_for_right_hip",
            "rightKnee": "actual_report_point_id_for_right_knee",
            "rightAnkle": "actual_report_point_id_for_right_ankle"
          }
        }
      ]
    }

This is an illustrative interface, not a runnable sample. Use the original
report's point IDs and reference timestamps. Unknown, duplicate, reused or
time-mismatched point IDs fail closed. Omit a marker from a frame if it is
unobserved; missing joints will not be synthesized.

## New: build the joint map from frozen multiview observations

The first version required manually constructing the joint timeline. The new
builder replaces that repetitive step when the upstream pose/correspondence
producer provides **explicit** anatomical labels.

In the *original* motionos.multiview-correspondences.v1 artifact, a point may
have:

    {
      "point_id": "frame-000012-leftKnee",
      "reference_time_ns": 1740000000000,
      "joint_name": "leftKnee",
      "observations": {
        "...": "existing calibrated camera observations, unchanged"
      }
    }

This example shows the optional label field, not a full valid triangulation
input. Add anatomical labels **before freezing and triangulating**: changing a
source file afterward breaks its SHA-256 binding to the geometry report.

Once the geometry report has been produced:

    motionos build-kinematic-joint-map \
      results/geometry.json \
      results/frozen-correspondences.json \
      results/joint-map.json \
      --subject-id local-pseudonym

The command verifies original source and geometry hashes, fixed rig ID, frozen
status, exact point IDs and nanosecond timestamps, no duplicate joint within a
frame, and approved landmark vocabulary. **It does not guess joint identity from
the filename or point ID.** Unlabeled points are excluded and counted. Unknown
or ambiguous labels fail explicitly.

When the model's labels need human review, create an optional separate,
immutably hash-bound annotation document:

    {
      "schema_version": "motionos.kinematic-joint-annotations.v1",
      "geometry_report_sha256": "ACTUAL_GEOMETRY_SHA256",
      "correspondences_sha256": "ACTUAL_CORRESPONDENCES_SHA256",
      "review_status": "human_reviewed",
      "labels": [
        {"point_id": "frame-000012-leftKnee", "joint_name": "leftKnee"}
      ]
    }

Then pass --reviewed-annotations results/reviewed-labels.json to the same
mapping command. The labels document is a human-declared review receipt; this
tool cannot independently prove that the anatomical assignment is correct.
Any conflict with an upstream frozen label fails closed rather than silently
overwriting raw evidence.

Every mapped joint retains **human_reviewed** or **model_proposed** status.
Legacy manual maps without such metadata remain **unverified**. The motion
timeline preserves the review status per frame and summarizes the counts.
Neither model proposals nor reviewed names certify true internal joint centers.

For real offline use, the two commands are therefore:

    motionos build-kinematic-joint-map \
      results/geometry.json results/correspondences.json \
      results/joint-map.json --subject-id local-pseudonym

    motionos build-personalized-kinematics \
      results/geometry.json results/rig.json results/world-frame.json \
      profiles/body.json results/joint-map.json results/kinematics.json \
      --trc results/markers.trc

A real body profile with a source scan SHA-256 also requires the
--body-source-artifact argument as documented below.

## CLI

    cd ~/Developer/multimodal-sport-lab
    python3 -m venv .venv
    source .venv/bin/activate
    python -m pip install -e '.[dev]'
    motionos build-personalized-kinematics \
      results/geometry.json \
      results/camera-rig-receipt.json \
      results/world-frame.json \
      profiles/personal-body.json \
      results/joint-map.json \
      results/personal-kinematics.json \
      --body-source-artifact scans/original-scan.obj \
      --trc results/personal-markers.trc

Omit --body-source-artifact only when a profile has no hash-bound physical scan.
Then body_model_personalized_source_verified will be false.

TRC requires a nearly uniform frame sampling grid (2% tolerance); an uneven or
gapped series must be preserved as JSON pending an explicitly reviewed
resampling stage. No hidden interpolation. Missing coordinates are blank in
TRC, never zeros. OpenSim IK configuration and coordinate conventions remain
a separate qualification task. See CLI --help for all thresholds.

## Scientific interpretation

| Field | Origin | Scientific status |
| --- | --- | --- |
| markers_world_m | Calibrated multiview triangulation | Derived 3D landmark estimate |
| joint_angles_deg | Three-marker geometric angle | Estimated knee flexion proxy |
| segment_length_relative_deviation | Marker distance versus personal model | Anatomical consistency diagnostic |
| rejected_joints | Reprojection and ray-quality gates | Explicit missing/unreliable evidence |
| body_model_personalized_source_verified | Source artifact hash | Source binding, not body-scan accuracy |
| Muscle activation, force, strain, injury risk | Unobserved in this stage | **Not estimated** |

An OpenSim anatomical joint center need not equal a vision landmark position.
Low reprojection error is not laboratory accuracy. The model never silently
rescales each frame to make a pose look consistent.

## Next integration gates

**M3-B: 3D Pose adapter.** Feed a reviewed multiview pose stack (e.g. Pose2Sim
with approved inference weights) into the existing multiview correspondence
contract with source-frame PTS and per-view confidence. Preserve occlusion and
failed frames. Evaluate held-out day, view, remount and movement speed.

**M3-C: OpenSim IK.** Pin a licensed model and dependencies, bind marker
correspondence and scaling, export joint-coordinate MOT/STO, and preserve fit
residuals and optimization failures. Validate against independent motion
reference before labeling the results quantitative biomechanics.

**M3-D: Contact force qualification.** The Indo Board is a coupled
body-deck-roller-ground system. Foot normal-pressure fractions alone do not
recover full 3D ground reaction, moment and center of pressure. Consume the
separate M2 sensor/teacher work only when real timing and force calibration
have passed.

**M3-E: Musculoskeletal force/activation estimates.** Use a declared
optimization objective and known external loads, independently test against
force and optional EMG data, and label predicted activation differently from
muscle force, tendon force and muscle length.

**M3-F: Anatomical video render.** Project the licensed anatomy mesh into
each source camera using calibration, depth/occlusion, and pose uncertainty.
Do not render simulated fibers as direct physiological measurement.

## Release boundary

Python, Apple host and replay CI establish engineering regression health only.
A physical multiview run and independent kinematic reference have **not yet
been collected or qualified**. Keep this as a research-only offline output.

Adjacent pending work: PR #130 capture readiness; #128 dynamics; #132–134
teacher/pressure source qualification; #136 capture postflight QA.
