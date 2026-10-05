# Action 4 Pose Replay v1

Status: physical beta runbook for the MotionOS multiview Indo Board session

## Goal

Produce one replay in which the imported DJI Osmo Action 4 source has:

- an immutable source hash;
- reviewed START / MIDDLE / END timing alignment;
- Action 4-local 2D body pose;
- optional Action 4-local QR deck / roller geometry;
- synchronized access to the iPhone-derived 3D body scene.

This runbook does **not** qualify metric multi-camera geometry.

## Before recording

Use MotionOS product protocol v2.

Keep the iPhone and Action 4 rigid for the complete run. Frame the full rider,
deck, roller, and lateral recovery space. A 45–90 degree viewpoint difference
between cameras is useful for the later geometry milestone.

For QR-backed equipment evidence, place the existing MotionOS markers where
they remain visible to both cameras:

- deck left;
- deck right;
- roller center, or the supported roller-left / roller-right pair.

QR physical size is only a visibility aid. It is not a scale calibration.

## Record

1. Start the Action 4 before mounting the board.
2. Start the MotionOS multiview session.
3. At each Watch sync cue, make the requested single sharp arm gesture:
   - START near 10 s;
   - MIDDLE near 63 s;
   - END near 114 s.
4. Finish and seal the MotionOS session.
5. Stop the Action 4 after the MotionOS run is complete.

Do not perform extra sharp sync-like arm gestures immediately around the three
declared landmarks.

## Import and synchronize

Open the sealed session in MotionOS and import the untouched Action 4 movie.

Then:

1. open **Replay**;
2. choose **Action 4**;
3. tap **Analyze Action 4 Sync**;
4. inspect the proposed START / MIDDLE / END correspondences;
5. tap **Review Three Landmarks**;
6. replay each paired iPhone / Action 4 landmark;
7. explicitly confirm only when both views show the same physical gesture;
8. seal the reviewed alignment.

The resulting `video-alignment.json` is the temporal authority. The proposal
file alone is not.

## Build source-camera pose

The sync analyzer already decodes the Action 4 source at 5 Hz. MotionOS now
persists those same body + QR observations as the **first usable pose track**
instead of discarding them. After temporal alignment is sealed, Video mode can
therefore become useful without immediately decoding the 4K movie a second
time.

Replay then offers **Refine Pose Track to 10 Hz** as an optional quality pass.

The refinement:

- verifies the Action 4 SHA-256 against the sealed alignment;
- samples the source at 10 Hz;
- runs Apple Vision human-body pose locally;
- runs the existing MotionOS QR detector on the same sampled frames;
- atomically replaces the coarser track only when the new track is denser;
- keeps the original movie unchanged.

A later 5 Hz sync rerun never overwrites an existing 10 Hz track.

For a two-minute protocol the refinement is intentionally offline. It may take
noticeably longer than normal replay loading because Vision is processing a
4K source. Closing Replay cancels the pass instead of allowing invisible work
to continue.

## Review

In **Video** mode:

- cyan skeleton = Action 4-local Vision 2D pose;
- green deck / roller = Action 4-local QR evidence when visible;
- confidence changes opacity / point size when enabled.

In **Body** mode:

- the 3D scene remains the temporally aligned iPhone-derived body state.

This separation is deliberate. MotionOS never paints iPhone pixel coordinates
onto Action 4 footage.

### Compare both cameras

After the alignment is sealed, Replay exposes **Compare Both Cameras**.

The comparison view:

- uses iPhone elapsed camera PTS as the reference transport;
- computes the exact shared playable interval before enabling the scrubber;
- never fabricates frames outside the interval where both sources exist;
- schedules both local AVPlayers against one host-clock start;
- maps Action 4 playback through the sealed affine clock;
- measures live player drift after mapping Action 4 back into reference time;
- corrects Action 4 scheduling only after drift exceeds the review threshold;
- keeps correction count visible as a playback diagnostic;
- provides direct START / MIDDLE / END jumps to the reviewed landmarks;
- shows iPhone and Action 4 source-specific overlays in their own image planes.

The live drift number is **not** the alignment uncertainty. It answers a
different question: whether two local AVPlayers are currently presenting the
already-aligned evidence at the same reference instant. The alignment RMS and
anchor uncertainty remain the temporal-evidence authority.

If the source video begins late or ends early, the comparison slider is clipped
to the true overlap. A missing interval is shown as unavailable rather than
mapping it to frame zero or the last source frame.

## Passing first physical beta

A useful first run should show:

- all three sync landmarks correctly proposed and manually verified;
- sealed timing coverage across early / middle / late session time;
- Action 4 pose track present for most of the visible-rider interval;
- skeleton follows the rider without long frozen segments;
- no skeleton persists through a long Vision dropout;
- QR deck / roller overlay appears only when the marker set is actually
  recognized;
- source hashes remain unchanged;
- Replay remains responsive while switching iPhone / Action 4 and Video / Body;
- **Compare Both Cameras** starts inside the true shared interval, scrubs both
  views to the same physical instant, and does not synthesize non-overlap;
- START / MIDDLE / END jumps visibly land on the same reviewed gestures in both
  panes;
- live player drift normally remains inside the 90 ms correction envelope
  during local-file playback, with any corrections counted rather than hidden.

Record any false pose, wrong-person pose, orientation error, QR misidentification,
or timing mismatch as a beta defect. Do not tune thresholds against one failed
run without preserving that evidence.

## What comes next

The next geometry gate is calibrated multiview:

1. ChArUco calibration-board definition;
2. Action 4 and iPhone intrinsics / distortion;
3. frozen world frame;
4. capture-time mount verification;
5. camera-rig qualification;
6. time-matched cross-view correspondences;
7. triangulation with reprojection diagnostics.

Only that chain can promote the two image-space views into metric world-frame
claims.
