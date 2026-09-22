# Camera + Vision 3D Evidence Contract

MotionOS treats camera/video as another independently timed evidence source.

The camera layer is not allowed to overwrite Watch time, equipment time, or
insole time during capture.

## Source files

A closed iPhone camera session contains:

~~~
camera.mov
camera-frames.jsonl
camera-metadata.json
~~~

The MOV and frame journal are generated from the same
`AVCaptureVideoDataOutput` delivered frames.

## Raw time authority

Every delivered frame uses the source sample buffer's presentation timestamp:

~~~
device_time_ns = AVCapture CMSampleBuffer presentation timestamp
timestamp_basis = "avcapture_presentation_timestamp"
~~~

That timestamp remains raw camera/video time until a later
`motionos.clock-sync.v1` correspondence maps it to the Watch/reference clock.

## Streams

### `/camera/frame`

One event for every delivered video-data frame.

The event records frame sequence, raw PTS, whether the frame was appended to the
MOV writer, pose scheduling/result status, frame dimensions, orientation policy,
and camera intrinsics when AVFoundation provides them.

Valid pose statuses are:

~~~
not_scheduled
detected
no_pose
vision_error
~~~

No missing pose is filled or interpolated during capture.

### `/camera/pose3d`

Emitted only when Vision returns a 3D body-pose observation for a scheduled
source frame.

The payload preserves the exact source-frame sequence and PTS, root-joint-
relative 3D joints in meters, parent-joint topology, body-height metadata,
Vision camera-origin matrix, and explicit coordinate-frame semantics.

## Vision coordinate-frame boundary

Vision 3D joint positions are represented in meters with the root joint as the
skeleton origin.

MotionOS therefore stores:

~~~
joints_root_relative_m
joint_coordinate_frame = vision_root_joint_relative_meters
~~~

The camera relationship is preserved separately through:

~~~
camera_origin_matrix
camera_origin_semantics = transform_from_skeleton_root_to_camera
~~~

Do not rename the root-relative joint array to camera coordinates.

Do not promote it to world/body coordinates without an independently validated
spatial calibration.

## Camera intrinsics

When the active video connection supports intrinsic-matrix delivery, MotionOS
enables it before capture starts.

Per-frame intrinsics are preserved as a 3x3 matrix together with the frame
dimensions used as the intrinsic reference dimensions.

If intrinsics are unavailable, the frame remains valid evidence. MotionOS
records that the hardware/format did not provide them rather than inventing
values.

## Video writer

The camera MOV uses AVFoundation-recommended writer settings for the configured
capture output.

The video writer and frame journal consume the same delivered sample buffer.

If the writer cannot accept a delivered frame immediately, MotionOS records
`video_written=false` and increments the writer-backpressure count.

A P5A capture receipt does not pass if any delivered frame was omitted from the
MOV.

## Capture-output drops

`AVCaptureVideoDataOutput` is configured to discard late video frames rather
than allow an unbounded processing backlog.

AVFoundation's drop callback becomes:

~~~
/camera/drop
~~~

with the dropped sample's PTS.

This distinguishes a frame delivered to MotionOS but rejected by the writer
from a frame that AVFoundation dropped before normal delivery.

Neither case is silently interpolated.

## Pose scheduling

Initial M0 policy:

~~~
pose_stride_delivered_frames = 3
~~~

Vision is intentionally not required on every video frame.

Every video frame still records whether pose was scheduled and what happened.

This makes compute overload and model non-detection observable.

## Derived camera-motion stream

During Python import, successive valid Vision pose observations produce:

~~~
/camera/pose_motion
~~~

with:

~~~
motion_m
speed_m_s
delta_time_s
source_pose_sequence_previous
source_pose_sequence_current
derived = true
~~~

`motion_m` is the Euclidean change in the translation component of successive
Vision camera-origin transforms.

It exists to create a simple timing landmark signal for camera-to-Watch
synchronization.

It is derived timing evidence, not a claim about athlete center-of-mass motion
or biomechanics.

## Provenance

When camera recording closes, the iPhone computes SHA-256 for:

- `camera.mov`
- `camera-frames.jsonl`

The Python importer additionally hashes `camera-metadata.json`.

The MotionOS camera session carries all three hashes.

The capture receipt cross-checks the sidecar's MOV/journal hashes against the
actual imported source bytes.

## Capture receipt

`capture_passed=true` requires:

- at least two delivered frame events;
- minimum requested duration;
- monotonic frame PTS;
- contiguous delivered-frame sequence;
- valid frame payloads;
- every delivered frame written into the MOV;
- sidecar counts agreeing with the journal;
- sidecar first/last PTS agreeing with the journal;
- MOV/journal SHA-256 agreeing with the sidecar;
- imported source hashes present.

`pose_evidence_present=true` additionally requires:

- at least two valid Vision pose observations;
- at least one derived camera-motion observation;
- pose events linked to an existing source frame at exactly the same PTS;
- valid root-relative joint arrays;
- valid 4x4 camera-origin matrices.

Full `passed=true` requires both.

## Generic clock mapping

After camera capture is independently qualified:

~~~
motionos derive-clock-sync \
  WATCH_SESSION \
  CAMERA_SESSION \
  camera-sync-windows.json \
  camera-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /camera/pose_motion \
  --target-keys motion_m
~~~

Use deliberate shared motion visible in both modalities near start, middle, and
end.

Do not let the tool search the full recording for whichever peaks happen to
agree.

## Claim boundary

Camera + Vision evidence can serve as a teacher, visualization, and validation
source.

It does not by itself establish motion-capture-grade 3D accuracy, world-
coordinate pose, joint-angle accuracy, center-of-mass accuracy, biomechanical
validity, or clinical validity.
