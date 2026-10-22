# M2.1 Source-bound video and sensor qualification

Status: private scientific evidence-binding check, NOT a measured biomechanics
model and NOT an authorization to use participants' recordings for training.

This is a stacked extension of docs/video-teacher-dataset-v1.md.

## Contract and invariant

The tool re-verifies the candidate index and checks original video evidence,
its video-to-reference alignment, source-native sensor streams, the original
reference and target MotionOS sessions, and the sensor-to-reference clock
synchronization. In particular it requires:

- exact original video SHA256, run ID and source metadata reference_session_id;
- three or more valid video landmarks with early/middle/late coverage;
- original sensor stream from the referenced target session, NOT an arbitrary
  re-exported JSONL masquerading as a sensor label;
- clock receipt recomputation against original hashed reference/target M0
  sessions, matching reference session ID and target stream;
- video and sensor timing residual RMS <= 20 milliseconds each;
- at least 20 in-window sensor samples and 2 seconds of observed time;
- at least 80% of the video reference window occupied by contiguous measured
  samples, counting only gaps <=500 ms;
- sensor timestamps monotonic and duplicate-free; any declared reference
  timestamps agree with the recomputed model within 20 ms.

These limits are source-binding QA floors to catch obvious pilot failures,
not sufficient evidence for any particular physiological accuracy.

## Example private spec

Place the following structure in private/qualify.json and replace every path
and ID with genuine capture evidence. All files must exist.

    {
      "schema_version": "motionos.teacher-source-qualification-spec.v1",
      "candidate_index": "candidate-index.json",
      "samples": [{
        "sample_id": "trial-001",
        "reference_session": "sessions/watch-reference",
        "video_alignment_receipt": "sync/video-to-watch.json",
        "labels": [{
          "target_id": "left_load_fraction",
          "modality": "bilateral_pressure",
          "sensor_session": "sessions/insole-evidence",
          "sensor_stream": "/insoles/bilateral/pressure",
          "clock_sync_receipt": "sync/insole-to-watch.json"
        }]
      }]
    }

The video-alignment creation spec must include a source_metadata object with
reference_session_id equal to the M0 reference session manifest session_id.
Use existing video-alignment and derive-clock-sync commands to generate
those receipts from actual physical source evidence.

## Commands

    motionos qualify-teacher-sources private/qualify.json private/audit.json
    motionos verify-teacher-sources private/audit.json

The resulting motionos.teacher-source-qualification.v1 report stores hashed
source identities, timing quality, and observed sensor duration for each
candidate, with source_binding_passed=true and training_ready=false.

It deliberately does NOT check consent documents, physiology calibration,
EMG electrode placement, pressure zeroing, the numeric validity of each sensor
payload, or the real-world truth of declared synchronization gestures.
A convincing video overlay does not replace those checks.

## Next research gate

Independently verify actual participant authorization/withdrawal, equipment
calibration and contact references, units/frames, numeric time-series values,
missingness masks and subject-held-out evaluation. Only that later gate may
consider publishing a frozen training-eligible dataset.

The user-facing Capture flow remains untouched. A research-sensor readiness
panel should be a separately opt-in, progressive disclosure, rather than a
mandatory obstacle between users and the Record button.

Tests use synthetic sessions and clock anchors. They demonstrate validation
behavior, not evidence of any successful real-device capture.
