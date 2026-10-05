# Replay Annotation Worklist v1

Status: offline review bridge from synchronized replay QA to human annotation.

## Purpose

MotionOS replay flags identify exact moments worth inspecting. The replay review
queue converts those markers into hash-bound time windows. The annotation
worklist now binds those windows to the already validated teacher-label frames
that fall inside them.

This closes a useful product loop:

```text
capture
  -> synchronized replay
  -> human review flag
  -> exact replay-review window
  -> candidate teacher-label frames
  -> explicit human annotation/correction
```

The final arrow remains intentionally manual. A review flag is not a correction,
and an existing model label is not promoted to truth merely because it falls
inside a flagged window.

## Build a worklist

```bash
motionos build-replay-annotation-worklist \
  replay-review-queue.json \
  annotation-manifest.json \
  teacher-labels.jsonl \
  replay-annotation-worklist.json
```

The builder validates the annotation manifest and teacher-label stream first,
then fails closed if the replay queue belongs to a different run, Action 4
source video, or alignment receipt.

## Output

Each work item preserves:

- review task and original flag identity;
- scope, verdict and reviewer note;
- exact reference and Action 4 source windows;
- pose/equipment evidence availability;
- candidate teacher-label frame IDs within that window;
- whether the task has label candidates or requires video-only review.

Candidate frames preserve their source PTS, reference time, current human review
state, field classes and model versions. The worklist also binds the queue,
annotation manifest and teacher labels by SHA-256.

## Why this matters

During an Indo Board session, a tester can now tap a flag exactly when the pose,
board overlay, timing or coaching looks wrong. Offline review can jump directly
to the corresponding teacher-label frames instead of searching a complete
recording. Good examples can be routed through the same evidence path.

That makes the dataset grow from actual product use while preserving the
distinction between:

- observed evidence;
- derived geometry;
- inferred behavior/coaching;
- explicit human correction.

## Scientific boundary

The worklist is review orchestration. It does not modify labels, assign accepted
review state, establish metric camera geometry, measure force/COM, or convert
estimated muscle demand into measured activation.
