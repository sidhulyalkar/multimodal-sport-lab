# Personal Movement Baseline v1

Status: M1.0 descriptive longitudinal baseline contract.

## Goal

MotionOS should compare an athlete primarily against their own repeated,
reviewed evidence before it tries to prescribe generic technique.

The first baseline is intentionally modest. It summarizes accepted numeric
movement fields across repeated sessions while preserving exact context and
source provenance.

It is **not** an athlete score and it is **not** an ideal-form model.

## Baseline spec

A baseline spec declares:

- a local pseudonymous `profile_id`;
- one sport;
- explicit metrics, evidence classes and units;
- optional equality selectors;
- one or more reviewed-label sessions;
- exact context for each source session.

Example:

```json
{
  "schema_version": "motionos.personal-movement-baseline-spec.v1",
  "profile_id": "local-athlete",
  "sport": "indo_board",
  "metrics": [
    {
      "id": "neutral-pelvis-offset",
      "evidence_class": "derived",
      "field": "pelvis_offset_m",
      "unit": "m",
      "selectors": {
        "inferred.movement_primitive": "neutral_balance"
      }
    }
  ],
  "sources": [
    {
      "reviewed_labels": "run-001/reviewed-labels.jsonl",
      "reviewed_labels_receipt":
        "run-001/reviewed-labels-receipt.json",
      "annotation_manifest": "run-001/annotation-manifest.json",
      "context": {
        "protocol": "indo_2min_v1",
        "drill": "neutral_balance",
        "stance": "regular",
        "equipment": "indo_board"
      }
    }
  ]
}
```

Units are declared explicitly in the spec. The baseline builder never guesses
units from a field name.

## Build

```bash
motionos build-personal-movement-baseline \
  personal-baseline-spec.json \
  personal-movement-baseline.json
```

## Trust rules

Every source must include:

1. reviewed labels;
2. the reviewed-label materialization receipt;
3. the annotation manifest.

The builder verifies the hashes carried by the materialization receipt, then
revalidates the reviewed labels against the annotation manifest.

Only rows with `human_review_state == "accepted"` contribute.

Rejected, insufficient-evidence, and unreviewed rows remain in their source
artifacts but do not enter the baseline.

## Context isolation

MotionOS does not silently pool different contexts.

Two sessions are combined only when their full context objects match exactly.
Changing stance, protocol, drill, equipment, or any other declared context
creates a separate baseline group.

This prevents an apparently precise distribution from being created by mixing
physically different tasks.

## Robust statistics

Each metric/context group reports pooled:

- sample count;
- median;
- median absolute deviation;
- q10 / q25 / q75 / q90;
- minimum and maximum.

It also reports session-level medians separately.

This distinction matters. Ten thousand video frames from one recording are
still one session.

For multiple sessions MotionOS reports the median and median absolute deviation
of the session medians. The status is still
`multi_session_descriptive`, not "qualified".

## Human corrections

The baseline records how many contributing samples contain an explicit human
correction to the metric itself. It does not give those rows artificial model
confidence or extra statistical weight.

## Next layer

M1.1 should compute a **session delta** against the matching baseline group:

- current median relative to personal median;
- change relative to normal within-person spread;
- whether context actually matches;
- whether enough repeated sessions exist to call the change unusual;
- the exact evidence supporting the comparison.

Only after that should a coaching layer translate deltas into suggestions.

## Scientific boundary

A personal baseline describes accepted reviewed evidence. It does not establish
measurement accuracy, ideal technique, injury risk, pathology, or causal
coaching benefit.

Repeatability is not accuracy.
