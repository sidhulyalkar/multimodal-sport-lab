# M3-B: calibrated multiview 2D pose handoff

**Status:** research adapter, not a physical-camera qualification.

This adapter is stacked on PR #137. It produces the exact
`motionos.multiview-correspondences.v1` format already accepted by
`motionos triangulate-multiview`. It does **not** estimate 3D muscle activity.

## Intended chain

1. Record iPhone, Watch, Action 4 and preserve original bytes.
2. Review/seal time synchronization and physical camera calibration.
3. Construct a **passing** `motionos.camera-rig-receipt.v1` containing the
   camera session identities, original source bundle hashes and clock models.
4. Extract per-camera, independently timestamped **2D source pose observations**
   with the video decoder's actual source-frame sequence and source PTS.
5. Confirm that both fixed views contain the **same single person**.
6. Produce frozen multiview correspondences (this adapter).
7. Triangulate using the existing M1 camera geometry implementation.
8. Build an anatomical joint map and the M3 personalized marker timeline.
9. Optionally export the resulting metric marker trajectory as a TRC file.

### IMPORTANT Action 4 compatibility boundary

The current `motionos.external-video-pose-track.v1` export includes joint IDs,
normalized image positions and native video PTS, **but not a source frame
sequence**. It is not directly accepted by this adapter. A subsequent
source-decoder export must retain each actual frame's sequence *at decode
time*, then convert it into the contract below, preserving exact PTS.
Do **not** invent an ordinal from 5/10Hz pose sample order. The input format
also requires an exact calibrated source session and original movie hash.
The camera rig requires physical calibration and source clock receipts; a
reviewed three-cue video overlay alone is **not** a metric 3D calibration.

## Source 2D pose track contract

Each camera has one `motionos.camera-pose-observations.v1` JSON file:

```json
{
  "schema_version": "motionos.camera-pose-observations.v1",
  "camera_id": "cam-a",
  "session_id": "camera-a-session",
  "session_bundle_sha256": "64-char session bundle digest from rig",
  "source_video_sha256": "64-char original video digest",
  "subject_id": "local-pseudonym",
  "image_size_px": [1920, 1080],
  "coordinate_frame": "source_image_normalized_origin_lower_left_after_orientation",
  "frames": [
    {
      "source_frame_sequence": 123,
      "source_frame_pts_ns": 12345000000,
      "subject_id": "local-pseudonym",
      "joints": [
        {"id": "leftHip", "x": 0.43, "y": 0.53, "confidence": 0.92}
      ]
    }
  ]
}
```

Alternatively a fully **oriented image-pixel** track may declare
`source_image_pixels_origin_upper_left_after_orientation`; then `x,y`
are source pixel coordinates, not normalized. Input image dimensions must
match the rig's **calibrated** frame exactly. The normalized origin conversion
is y-flipped and uses the [0,width-1]/[0,height-1] pixel-center range.
Only explicitly recognized anatomical joint names are eligible.

The manifest must refer to the **actual** immutable camera session and
original video bytes; source hashes are verified by reading the files.

## Handoff spec

```json
{
  "schema_version": "motionos.multiview-pose-handoff-spec.v1",
  "subject_id": "local-pseudonym",
  "anchor_camera_id": "cam-a",
  "operator_confirmed_single_person_identity": true,
  "min_joint_confidence": 0.5,
  "min_matched_points": 10,
  "min_matched_anchor_fraction": 0.5,
  "rig_receipt": {
    "path": "rig-receipt.json",
    "sha256": "ACTUAL_RIG_SHA256"
  },
  "camera_tracks": [
    {
      "camera_id": "cam-a",
      "track": {
        "path": "cam-a-pose.json",
        "sha256": "ACTUAL_CAM_A_TRACK_SHA256"
      },
      "original_video": {
        "path": "cam-a-original.mov",
        "sha256": "ACTUAL_CAM_A_MOV_SHA256"
      }
    },
    {
      "camera_id": "cam-b",
      "track": {
        "path": "cam-b-pose.json",
        "sha256": "ACTUAL_CAM_B_TRACK_SHA256"
      },
      "original_video": {
        "path": "cam-b-original.mp4",
        "sha256": "ACTUAL_CAM_B_VIDEO_SHA256"
      }
    }
  ]
}
```

All paths are relative to the spec file, unless absolute. To avoid
overselling spatial identity, the user/operator must affirm the single-person
association; this is a **reported check**, not a proven automatic ReID system.

## Commands

```bash
motionos build-multiview-pose-correspondences \
  handoff-spec.json correspondences.json \
  --audit correspondence-audit.json

motionos triangulate-multiview \
  camera-rig-receipt.json correspondences.json geometry-report.json

motionos build-kinematic-joint-map \
  geometry-report.json correspondences.json joint-map.json \
  --subject-id local-pseudonym

motionos build-personalized-kinematics \
  geometry-report.json camera-rig-receipt.json world-frame.json \
  personalized-body-model.json joint-map.json personalized-kinematics.json \
  --trc personalized-markers.trc
```

When the personal body profile declares a physical source scan digest, add
`--body-source-artifact <original-scan-path>` to the last command.

## Strict behavior

- Both input camera tracks must match the rig's exact camera and session
  identifiers, session bundle hashes and calibrated image dimensions.
- Every original video and pose JSON is SHA-256 verified.
- Pose frames must have **real** source frame sequence and monotonic source PTS.
- All time mapping uses the rig's frozen affine clock model, without
  extrapolating outside clock landmark support.
- Observations are matched by nearest **unique** camera frame within the
  predeclared rig tolerance. Exact ties are rejected as ambiguous. No
  interpolation or carry-forward is performed across occlusions.
- Clock predictive uncertainty must fit the time tolerance at 3 sigma.
- Only joints above the stated confidence threshold and observed in at least
  two cameras are exported.
- Inadequate point count or anchor-frame coverage fails the run.
- The separate audit records accepted-point coverage and failure reasons.
- Model-labeled anatomical joints remain **proposed**, not anatomically
  validated, in the downstream joint mapping.

### Scope limitations

This stage does not prove that independently identified `leftKnee` points
from two cameras correspond to the same precise anatomical joint center,
that camera extrinsics are correct, or that a pose estimator tracks fast 180s
without side swapping. It does not identify muscle excitation, force,
fiber-length changes, tissue strain, ground-reaction forces or injury risk.

Before producing meaningful biomechanics, benchmark held-out angles, occlusion,
fast motion, fixed versus remounted cameras, left/right swaps, and external
motion/force reference instruments. Work on source-native Action 4 frame-index
preservation in a separate Apple/camera-lane PR.
