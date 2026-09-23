# Personalized Body Model + Vision Registration

MotionOS can reference a 3D body scan as personalized geometry, but the scan and the camera teacher remain separate evidence layers.

The body model never replaces raw Vision pose.

## Schema

The personalized profile schema is motionos.body-model.v2.

Required concepts:

- model ID;
- height in meters;
- explicit body-frame convention;
- labeled metric landmarks;
- left/right segment lengths;
- optional joint limits;
- an explicit registration-landmark subset;
- source type and immutable source-artifact SHA-256;
- metadata/notes.

See examples/body_model.example.json.

## Asymmetry is data

MotionOS does not mirror one side to construct the other.

A profile may preserve different left/right femur, tibia, arm, and landmark geometry. If a scan or manual landmarking pipeline measures a real left/right difference, preserve it. A later model may regularize that difference, but raw personalized geometry should not silently assume bilateral symmetry.

## Source provenance

The body profile may declare the SHA-256 of the immutable source scan artifact. The profile file itself is also SHA-256 fingerprinted when loaded.

That gives two distinct provenance identities:

1. source scan artifact hash;
2. derived MotionOS body-profile hash.

Changing either artifact creates a new evidence version.

## Body frame

M0 uses an explicit body-model frame. The example convention is:

+X right
+Y up
+Z forward

A real scan profile may choose another convention, but the convention must be written into the profile. Do not infer the frame from the mesh orientation.

## Registration landmarks

The profile explicitly lists which landmarks are allowed to define the initial Vision-to-body-model transform. A recommended initial set is root, left/right hip, and left/right shoulder.

This is deliberately narrower than using every joint Vision can see. Hands, knees, ankles, and other articulated joints can move substantially between the scan pose and live camera pose. Including them automatically would let articulation masquerade as rigid registration error.

## Similarity transform

The M0 registration model is:

body_point = scale * R * vision_point + translation

R is a proper 3D rotation, scale is positive, and translation is metric.

MotionOS solves the 3D absolute-orientation problem from the declared landmarks with a dependency-free Horn/Davenport quaternion fit.

## Degeneracy gate

Registration requires at least three unique, non-collinear landmarks in both source and target geometry.

MotionOS rejects fewer than three landmarks, duplicated names, missing declared landmarks, coincident geometry, collinear configurations, non-positive fitted scale, and non-finite geometry.

It does not fabricate a transform from underconstrained geometry.

## Registration receipt

Every successful registered pose carries:

- profile ID and profile SHA-256;
- source pose sequence and source device timestamp;
- landmarks used;
- scale;
- 3x3 rotation;
- translation;
- per-landmark residuals;
- RMS residual;
- maximum residual.

The receipt is explicitly derived evidence.

## Raw-vs-derived boundary

Raw camera evidence remains /camera/pose3d with joints_root_relative_m and camera_origin_matrix.

Derived personalization is attached separately as registered_pose with joints_body_model_m and a registration receipt. The raw event is never rewritten.

## Replay behavior

When a calibration run references exactly one valid v2 body_model profile:

1. replay export loads and hash-verifies the profile;
2. each Vision pose attempts registration using only declared landmarks;
3. successful registration adds personalized registered pose;
4. raw Vision joints remain in the same replay frame;
5. registration residuals remain available for audit.

If profile loading or frame registration fails, replay continues with raw Vision teacher pose, registered_pose remains null, and the failure is explicit. No invisible fallback transform is used.

## 3D scan workflow

A real personal scan should ultimately produce two artifacts: the original mesh or point cloud and a body-model.json profile.

Recommended M0 process:

1. capture the body scan;
2. preserve original scan bytes;
3. hash the scan;
4. identify and record a body-frame convention;
5. mark torso/root registration landmarks;
6. measure left/right segment lengths independently;
7. write motionos.body-model.v2;
8. validate the profile;
9. reference the profile from the calibration-run manifest;
10. evaluate registration residuals over multiple calibration poses.

## What this does not prove

A low similarity-registration residual does not prove clinical anthropometric accuracy, optical motion-capture-grade kinematics, accurate joint centers, joint-angle validity, soft-tissue correction, or world-coordinate pose accuracy.

It means only that the declared Vision landmarks can be mapped consistently onto the declared personalized landmark geometry under the fitted similarity model.
