# Indo Board control insights v1

Status: **software implementation, pending physical qualification**.

This vertical slice connects existing board/roller image-plane observations to the iPhone
**Today**, **Session Detail**, and **Progress** tabs. It does **not** change the 120-second
Indo Board protocol or claim a continuous physiological fatigue estimate.

## Measurement contract

The estimator uses only `free-balance-a` (15–35 s) and `free-balance-b`
(85–105 s). Squats and intentional lateral shifts are not compared to the
natural-balance reference. It emits:

| Numeric key | Meaning |
|---|---|
| `board_control_early_center_fraction` | Fraction of accepted roller samples in the central ±0.20 zone during the first free-balance block |
| `board_control_repeat_center_fraction` | Same fraction during the repeat free-balance block |
| `board_control_center_change_pp` | Repeat minus first, in percentage points |
| `board_control_early_reversals_per_min` | Motion-sign reversals normalized by observed seconds in the first balance block |
| `board_control_repeat_reversals_per_min` | Same during repeat block |
| `board_control_positive_side_fraction` | Fraction of sufficiently off-center samples on the positive image-plane deck axis, **not foot loading** |
| `board_control_directional_samples` | Number of off-center samples used for the direction fraction |
| `board_control_early_observed_s` | Accumulated consecutive valid timestamp spans for the first block |
| `board_control_repeat_observed_s` | Accumulated consecutive valid timestamp spans for the repeat block |

### Fail-closed gates

- Each balance block must have at least 60% confident board-state coverage from
  the pose-observation timeline.
- Minimum board-state confidence is 0.55; nonfinite and out-of-range
  positions or timestamps are discarded.
- At least 30 valid samples and at least 6 seconds of valid consecutive time
  per matched block are required.
- Reversal-rate calculations ignore adjacent samples separated by >0.5 seconds,
  zero or negative timestamp deltas, and roller velocity <0.20
  normalized deck-half-lengths/second.
- The directional fraction requires at least 20 off-center samples.
- Recovery P90 in Session Detail is shown only when at least 3 recoveries are
  available and the matched-block insight gate has passed.

Existing session manifests and raw evidence remain unchanged. Derived values
are added to the optional `coachSummary.numericMetrics` dictionary. Sessions
created before this change continue to decode and show a clear unavailable state.

**Important:** These are sample-weighted image-plane proxies, not true time-weighted
force, balance recovery in 3D, EMG, fatigue diagnoses, or verified rehabilitation
metrics. Comparison after exercise may reflect many factors beyond fatigue.

## Training context

The session feedback form now optionally captures session intent
(skill practice, warm-up, active recovery, rehab tracking) and recent exertion
(fresh, some exercise, after hard exercise). Missing fields decode as `nil`
for older feedback files. Context does not automatically alter scores.

The Progress chart groups the completed runs by identical protocol version,
capture mode, intent, and recent exertion. This is a conservative first
comparison policy, not clinical adjustment or causal inference.

## Local acceptance checklist

1. Run `swift test --package-path apple/MotionOSAppleCapture`.
2. Regenerate using `cd apple/MotionOSHost && bash bootstrap.sh --no-open`.
3. Build the iOS and Watch simulator schemes. Confirm the first-run, Today,
   Record, Sessions and Progress tabs render on a small iPhone.
4. Open an older session without board metrics. Session Detail must say
   tracking evidence is insufficient; Progress must not plot a fake point.
5. Record a full 120-second Indo Board protocol with both deck and roller visible.
   Confirm both natural balance blocks have sufficient coverage and that the
   saved manifest contains new numeric keys when qualified.
6. Deliberately occlude the roller during one reference block. New matched
   metrics must be withheld when coverage fails.
7. Save context tags, reopen the session, edit them, reopen again, and ensure
   values persist without deleting original sensor journals.
8. Record or replay two sessions with different intent tags. Progress must
   refuse a direct trend until at least two comparable context-matched runs exist.
9. Check VoiceOver, Dynamic Type, landscape rotation, small-screen clipping,
   Watch start/resume, video playback, and interrupted capture recovery.
10. Independently review representative frames and annotate touchdowns,
    roller excursions, and recovery events before any hardware accuracy claim.

## Follow-on research

A genuine five-minute **Control Endurance** or stability-decay curve needs a
separate, deliberately structured endurance protocol and timestamp-weighted
quality-controlled windows. Asymmetrical foot loading needs bilateral pressure
or force instrumentation; raw image-plane roller sign alone does not qualify.
Rider-specific fatigue prediction requires held-out sessions with annotated
failures and task/context controls.
