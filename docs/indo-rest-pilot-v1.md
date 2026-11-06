# INDO BOARD recovery pilot v1

Status: **research implementation, not athlete guidance**.

## Scope

The new Python function motionos.indo_rest_pilot.build_indo_rest_pilot_report compares
two or more like-for-like baseline attempts, two or more later attempts, and
optionally two or more attempts following an explicitly recorded rest.

It reports signed metric differences and participant-reported effort. It does
**not** infer fatigue, injury risk, physiological recovery, or how long to rest.

The existing recovery_time_ms measures return of **board control** after a
movement excursion, not physiological recovery from exertion.

## Per-bout input contract

Every bout requires:

- bout_id, start_s, end_s (elapsed seconds in the same session);
- phase: reference, late, or post_rest, assigned by the protocol;
- context: skill_id, setup_id, stance_id, tracking_mode;
- source_verified: asserted true only after upstream artifact verification;
- source_digest_sha256: SHA-256 digest of the verified source;
- metrics: supported equipment-derived aggregate values;
- confidence: corresponding per-metric quality estimates in [0,1].

An optional effort_0_10 records the rider's perceived effort.

Currently supported: center_time_fraction, roller_excursion_p90,
deck_angle_abs_p90_deg from qualified board/roller tracking.

## Important safeguards

1. Comparisons require identical skill, setup, stance, and tracking mode.
   This deliberately avoids treating habitual asymmetry as an error.
2. At least two qualified bouts per comparison phase are required.
3. Low-confidence/missing measurements are excluded. The 0.75 gate is an
   engineering quality heuristic, NOT an empirically validated clinical cutoff.
4. The input source_verified flag is *not* cryptographically checked by this
   pure analysis function. The canonical ingest/receipt system must verify it.
5. Phase order is respected and source evidence must be checked independently.
6. No universal ideal stance, muscle-activation, center-of-pressure or injury
   claims are supported.
7. No personal HealthKit or provider-record data is included in public fixtures.

## Next integration stages

- **Collect:** add session bout and explicit rest-event annotations in the
  existing operator journal, with optional user effort ratings at natural pauses.
- **Qualify:** reuse existing source digest, clock-quality, framing, and
  equipment evidence gates to produce per-bout aggregates.
- **Summarize:** save a versioned derived/indo-rest-pilot.json alongside the
  canonical session manifest, linked to source artifacts and preprocessing.
- **Review:** show descriptive changes only, with transparent missing-data
  reasons; do not present experimental changes as recovery prescriptions.
- **Evaluate:** compare fixed intervals, perceived effort, CV-only, Watch-only,
  and combined predictors on session-held-out and later prospective sessions.

## Validation

Locally tested with nine synthetic pytest cases. Run:

    pytest -q tests/test_indo_rest_pilot.py
    ruff check src/motionos/indo_rest_pilot.py tests/test_indo_rest_pilot.py

This tests software invariants, NOT real sensor fidelity, safety, or
rest-effectiveness. Native iPhone/Watch integration is out of scope.
