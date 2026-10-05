# Replay Review Queue v1

Status: offline QA / annotation bridge for evidence-bound MotionOS replay flags

## Purpose

`replay-review-ledger.json` records moments a human flagged while inspecting the
synchronized iPhone + Action 4 replay. The queue builder turns those moments
into exact, reproducible time windows for later debugging, annotation, and
dataset construction.

It does not create labels automatically. It preserves where a human asked the
system to look.

## Build a queue

After exporting the review ledger and its sealed Action 4 alignment:

```bash
motionos build-replay-review-queue \
  replay-review-ledger.json \
  video-alignment.json \
  replay-review-queue.json
```

The builder fails closed when:

- the ledger and alignment belong to different runs;
- a flag does not bind the exact alignment SHA-256;
- a flag does not bind the Action 4 source hash sealed by that alignment;
- the stored Action 4 PTS does not recompute from the reference clock;
- a review window maps outside the shared playable interval;
- duplicate flag IDs or malformed review semantics are present.

## Queue semantics

Each task contains:

- the original review flag ID;
- scope and human verdict;
- center reference time;
- center Action 4 source PTS;
- a clipped reference-time review window;
- the exact Action 4 source-PTS window obtained through the sealed affine map;
- pose/equipment availability captured at review time;
- playback drift as a diagnostic;
- the original artifact bindings.

A default in-app flag covers 1.5 seconds before and after the marked instant.
The offline queue clips that window to the true common playable interval rather
than fabricating unavailable source time.

## Intended downstream use

The queue is designed to feed a later annotation worker that can:

1. open only the flagged windows instead of re-reviewing a complete run;
2. prioritize human-marked errors for pose/equipment model debugging;
3. collect good examples as positive exemplars;
4. distinguish occlusion/evidence gaps from genuine model errors;
5. preserve train/evaluation provenance when a reviewed frame later becomes a
   human-corrected label.

The queue itself is not training truth. A separate explicit human-correction or
teacher-label step is still required before geometry enters a trusted
evaluation dataset.

## Scientific boundary

Replay flags and queue tasks are human QA evidence tied to preserved source
hashes and reviewed temporal alignment. They do not establish metric camera
geometry, force, center of mass, muscle activation, diagnosis, or runtime model
qualification.
