# M1 Clock Uncertainty Analysis

M0 deliberately keeps `motionos.clock-sync.v1` simple and auditable: explicit
physical landmark windows, an affine target→reference mapping, raw residual RMS,
and exact source-session provenance.

M1 needs a different question:

> How uncertain is the mapped reference time at this target-device timestamp?

This document defines a **derived analysis layer**. It does not rewrite or
reinterpret the stored M0 receipt.

## Command

Given the exact sessions used by a v1 receipt:

```bash
motionos analyze-clock-uncertainty \
  data/p0/<watch-session> \
  data/p1/<pod-session> \
  pod-to-watch.clock-sync.json \
  pod-to-watch.clock-uncertainty.json
```

The command first revalidates every M0 v1 invariant against the exact session
bundle hashes. A stale or forged v1 receipt cannot be upgraded into an M1
analysis.

## Landmark uncertainty semantics

M0 v1 preserves `uncertainty_ns` for each deliberate correspondence but does
not give that field a calibrated probability interpretation.

For this M1 analysis, MotionOS explicitly records the assumption:

```text
uncertainty_ns is treated as one-sigma-equivalent timing uncertainty
```

This assumption is visible in the generated artifact and must be tested against
real physical repeatability.

A v1 landmark with `uncertainty_ns = 0` is treated as **missing uncertainty**,
not perfect timing.

The analysis fails unless an explicit fallback is provided:

```bash
motionos analyze-clock-uncertainty \
  ... \
  --default-uncertainty-ms 5
```

The fallback value is written into the analysis receipt.

## Weighted affine fit

For correspondences

```text
x_i = target device time
y_i = reference time
u_i = declared timing uncertainty
```

M1 fits:

```text
y = a + b x
weight_i = 1 / u_i²
```

The implementation centers time at the weighted mean before fitting so the
parameter covariance is numerically stable even for nanosecond timestamps.

The artifact reports:
- slope and drift ppm;
- intercept;
- ordinary residual RMS;
- reduced chi-square;
- covariance at the weighted time origin;
- slope/drift standard error;
- observation support start/end.

If residual scatter is larger than declared uncertainty predicts, covariance is
inflated rather than shrunk.

## Query-time uncertainty

Query any target-device timestamp:

```bash
motionos query-clock-uncertainty \
  pod-to-watch.clock-uncertainty.json \
  123456789012
```

Output includes:

```text
mapped_reference_time_ns
fit_parameter_std_ms
predictive_std_ms
extrapolated
distance_outside_support_s
```

`fit_parameter_std_ms` is uncertainty from the fitted affine parameters.

`predictive_std_ms` additionally includes the observed affine residual RMS as
a model-discrepancy term.

These are uncertainty estimates under the stated assumptions, not guaranteed
coverage intervals.

## Extrapolation

Parameter uncertainty naturally increases away from the landmark center.

The query marks a timestamp as `extrapolated=true` whenever it falls outside
the first/last landmark support and reports the distance outside that support.

Do not compare short physiological/mechanical lags against a timing uncertainty
of similar magnitude and then describe the lag as resolved.

## Leave-one-landmark-out diagnostic

Every correspondence is removed once.

The remaining landmarks fit a weighted affine model and predict the held-out
correspondence.

The report preserves:
- held-out error per landmark;
- whether prediction required extrapolation;
- held-out predictive uncertainty;
- RMS/max absolute error.

This is particularly useful for detecting a sync landmark that makes the full
fit look better only because it is included in the fit.

## Discontinuity diagnostics

M1 reports, without inventing a universal pass threshold:
- adjacent segment drift ppm;
- maximum jump between adjacent local slopes;
- maximum adjacent residual jump;
- residual trend over the recording.

A large value is a reason to inspect the source clock and landmarks, not an
automatic proof of a hardware clock reset.

## Affine versus piecewise diagnostic

With at least six landmarks, MotionOS additionally fits candidate continuous
two-slope models with interior breakpoints.

The report compares affine and best piecewise candidates using penalized AICc.

A positive:

```text
delta_aicc_affine_minus_piecewise
```

means the best tested continuous piecewise model has lower AICc.

This **does not automatically switch the replay clock model**. A piecewise
mapping requires evidence review and a separate versioned mapping contract.

With fewer than six landmarks the diagnostic is explicitly unavailable.

## Why keep M0 v1 untouched?

The M0 receipt answers:

> Which physical correspondences were declared, and what affine model did the
> existing qualification pipeline fit?

The M1 analysis answers:

> Given those exact correspondences and explicit uncertainty assumptions, how
> stable is that mapping and how uncertain is a particular mapped time?

Keeping those questions separate preserves reproducibility.

## Claim boundary

A low timing uncertainty means the declared timing evidence is internally
consistent under this model. It does not validate:
- sensor physical accuracy;
- video pose accuracy;
- biomechanical causality;
- whether landmark uncertainty is truly Gaussian.

Those require independent evidence.
