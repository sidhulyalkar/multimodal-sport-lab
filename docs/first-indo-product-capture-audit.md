# First Indo Board product capture: exported-evidence audit

This read-only audit checks file presence, basic JSONL structure, and SHA-256
links against the signed/sealed MotionOS product manifest after **the user
exports their original files from the iPhone**. It is not a fitness score,
physical device qualification, clock-fitting tool, or biomechanics validator.

## Expected export layout

MotionOS keeps the original evidence in separate directories under its
iPhone application Documents folder:

    Documents/
      MotionOSRuns/<run-id>/
        product-session.json
        operator-events.jsonl
        operator-metadata.json
        external/action4/original-*.mp4    (optional)
      MotionOSInbox/<watch-session-id>/watch.jsonl
      MotionOSCamera/<camera-session-id>/
        camera.mov
        camera-frames.jsonl
        camera-metadata.json

The sidecar IDs are taken from product-session.json; do not rename them.
An exported product **run folder alone is insufficient** to prove the Watch
journal or camera movie is missing on the iPhone. If the sibling directories
were not exported, missing source reports are pending/incomplete, not
automatic evidence of capture loss.

## Export and audit

Using Finder's iPhone File Sharing view, select MotionOS and save/copy the
original application Documents folder (or inspect the development app
container via Xcode Devices and Simulators). Do not edit, transcode, or
flatten the directory structure before auditing. Avoid sharing raw identifying
video or unredacted sensor evidence publicly.

From a checkout with this feature installed:

    python -m pip install -e ".[dev]"

    motionos audit-product-run       "/path/to/iPhone-Documents/MotionOSRuns/<run-id>"       --report "/path/to/private-capture-audit.json"

When you have only copied some siblings and they live elsewhere, you can
supply a --documents-directory pointing at a complete Documents-like root.
The tool never rewrites raw evidence, nor can it place the audit report within
that exported Documents tree.

Exit 0: exported original source files are present and hash-bound; note that
the report still sets physical_capture_qualified=false.
Exit 2: integrity_problem or incomplete_evidence. Inspect 'issues' and
'warnings' separately. A missing Watch journal may simply mean transfer is
pending or the exported folder is incomplete.

## What it inspects

- Existing run-specific operator metadata and ordered JSONL events.
- Product session run ID and completed/aborted outcome.
- Watch journal identity, expected digest and byte count when transferred.
- Original iPhone movie, camera frame journal and camera metadata.
- START / MIDDLE / END cue labels and duplicate-cue anomalies.
- Original external Action 4 movie and digest only if Multiview was chosen
  and the video was imported into that run.
- Source mismatches, missing sidecars, JSONL parsing issues, and absent
  digest fields are reported explicitly.

No sensor signal continuity, optical pose accuracy, actual sync-event timing,
model agreement, medical interpretation, personal athletic ability,
ground-reaction forces or EMG activity can be concluded from this report.
It is primarily a **forensic record-retention and handoff checkpoint**.

## First test priorities

1. Capture the current 120-second Indo Board v2 protocol in Watch + iPhone mode.
2. Check the sealed session inside the app, including whether the Watch
   transfer becomes verified and a video is inspectable.
3. Copy the original Documents folder before cleaning up local storage.
4. Run this audit and keep its report in private storage.
5. Review framing, dropped frames, source coverage and the sync-cue video
   manually; use separate MotionOS P0/P5A tools when scientifically qualified
   timing analysis is needed.

A report with all exported hashes matching remains software evidence only.
