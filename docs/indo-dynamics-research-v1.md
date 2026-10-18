# Indo Board dynamics v1: gap-aware longitudinal research probe

**Status:** experimental research analysis, not a biomechanically validated product feature.

## Research question

Can changes in board-relative control over matched, repeated Indo Board sessions be detected separately from camera artifacts and changes in task difficulty? We need falsifiable movement descriptors, not an overall skill score.

The existing board-state pipeline produces frame-count fractions and can detect recoveries spanning tracking gaps. This extension adds time weighting, coverage gates, event censoring, and explicit abstention.

## Run

~~~bash
python -m pip install -e '.[dev]'
motionos-balance-study board-observations.json balance-dynamics.json
pytest -q tests/test_indo_dynamics.py
~~~

Input follows the existing board observation schema: frames with time_s, deck endpoints, roller endpoints, and per-object confidence. Output schema is motionos.indo-dynamics.v1, with source_sha256 over the exact input bytes.

## Meaning of the output

- quality: qualified frames, observed exposure, recording span, coverage, contiguous tracking segments.
- status: descriptive_only or insufficient_evidence, with abstention reasons.
- metrics: time-weighted center/edge fractions; RMS image-space roller speed; excursion event rate per observed minute; settled fraction. Median settling time requires three confirmed events; side-specific medians require three per side.
- episodes: directional excursion start, peak, end and either settled or censored outcome.
- config: all thresholds used to derive the analysis.

Defaults: minimum detector confidence 0.65, maximum uninterrupted gap 0.25 seconds, minimum 70% temporal coverage, minimum 5 seconds of exposure, and minimum 20 qualified frames. An excursion begins on a crossing outward through absolute normalized roller position 0.35. Settling requires continuous observed time of at least 0.3 seconds inside absolute normalized position 0.15. An episode already underway when recording begins is not called a new excursion. These are initial engineering choices, not clinically or experimentally optimized constants. Lock them before a held-out study.

**Scientific limit:** image-plane roller position is not calibrated whole-body COM, contact force, muscle activation, balance skill, or physiological reaction time. The reported settling time is an event duration, not neural latency. RMS speed is vulnerable to camera jitter. Do not route these quantities directly to authoritative coaching.

## First falsifiable single-subject study

Collect 12 to 20 sessions across four or more days, initially using visible board and roller fiducials plus Watch capture. A short repeatable protocol includes quiet stance, natural balance, controlled lateral shifts and a second natural-balance block. Keep stance, board geometry, roller, camera mounting, footwear and protocol fixed within matched conditions. Save setup context once rather than asking for it repeatedly. Include intentionally remounted camera sessions to quantify setup variability.

H1: across matched natural-balance blocks, the fraction of observed time near the edge decreases with practice. H2: conditional on excursions of similar starting amplitude, settling duration decreases. H3 (exploratory): asymmetry and coordination patterns change, but symmetry is not assumed to be a universal target. Counterhypotheses: better-looking results arise from changed task difficulty, missing observations, learning the measurement protocol, or camera remount.

Predeclare the primary endpoint, exclusion criteria and minimum meaningful effect size. Group splits by session/day/remount, never by adjacent frames. Review a blinded subset of trajectories manually, vary confidence and gap gates in sensitivity analyses, and report independent sessions as the statistical unit. Randomize coaching versus no-cue blocks only after observational repeatability is demonstrated. Do not infer causal coaching value from a simple before-and-after contrast.

## Roadmap

1. Qualify measured timestamps, frozen camera calibration, stable fiducial tracking, physical iPhone/Watch recordings and replay audit.
2. Assemble a cross-modal event atlas from body pose, deck/roller, and wrist IMU with explicit alignment uncertainty. Relative signal lag is not reaction time.
3. Join reviewed episodes to exact-context personal baselines and held-out session deltas, guarding against self-comparison and protocol leakage.
4. Evaluate randomized nonhazardous coaching cues against neutral controls.
5. Add calibrated multiview 3D joint kinematics and personalize anthropometry only where needed. Anatomical muscle animations should be labeled illustrative until validated EMG is available.

## Athlete-facing UX

Default loop: Ready → Record → One meaningful observation → Replay → Compare next time. Research mode can expose QR marker kit, source hashes, annotation worklists, calibration details, quality gates and raw metrics. Remember a valid setup, show only the next actionable problem, preserve partial recordings if an optional sensor disconnects, and avoid promising progress when evidence is insufficient.
