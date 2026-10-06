# Personal Session Delta v1

Status: M1.1 descriptive comparison against a personal baseline.

## Product question

The Personal Movement Baseline answers:

> What does this athlete normally look like in this exact context?

The Personal Session Delta answers the next question:

> How did this new reviewed session differ?

It intentionally stops there.

A larger pelvis offset, faster correction, or narrower distribution is not
automatically better or worse without a separately validated interpretation.

## Spec

```json
{
  "schema_version": "motionos.personal-session-delta-spec.v1",
  "baseline": "personal-movement-baseline.json",
  "baseline_sha256": "<exact baseline sha256>",
  "source": {
    "reviewed_labels": "new-run/reviewed-labels.jsonl",
    "reviewed_labels_receipt":
      "new-run/reviewed-labels-receipt.json",
    "annotation_manifest": "new-run/annotation-manifest.json",
    "context": {
      "protocol": "indo_2min_v1",
      "drill": "neutral_balance",
      "stance": "regular",
      "equipment": "indo_board"
    }
  }
}
```

Build with:

```bash
motionos build-personal-session-delta \
  personal-session-delta-spec.json \
  personal-session-delta.json
```

## Leakage guard

The current session may not already be one of the source runs used to build the
baseline.

This matters because comparing a session against a baseline that already
contains the same session artificially shrinks the apparent delta.

## Exact context

A comparison is made only against baseline groups whose full context object
matches the current source exactly.

If no context matches, MotionOS emits a valid artifact with
`context_match=false` and no comparisons. It does not silently fall back to a
different stance, drill, board, protocol, or other context.

## Metrics

For every matching baseline group the artifact reports:

- the current accepted-sample distribution;
- current median minus personal baseline median;
- delta in pooled baseline MAD units when defined;
- delta in session-median MAD units when a multi-session baseline supports it;
- whether the current median lies below q10, within q10-q90, or above q90 of
  the baseline distribution;
- human-corrected sample count.

The two MAD normalizations are kept separate.

Pooled frame spread and across-session spread answer different questions.

## Single-session baseline

A delta can be computed against a one-session baseline, but its status explicitly
says `descriptive_against_single_session_baseline`.

MotionOS must not present this as established longitudinal behavior.

## No coaching yet

M1.1 deliberately does not contain:

- better/worse labels;
- technique grades;
- injury-risk interpretations;
- exercise prescriptions;
- coaching suggestions.

Those require an interpretation layer with validated directionality and evidence
for the advice.

## Next layer

M1.2 should introduce an evidence-backed interpretation contract. A coaching
candidate should have to identify:

1. the personal delta supporting it;
2. the directionality rule or validated model used;
3. confidence/qualification state;
4. a contraindication or abstention path;
5. whether the suggestion is generic, personalized, or experimentally learned.

The UI can then say **what changed** even when MotionOS appropriately abstains
from saying **what you should change**.

## Scientific boundary

A personal session delta is descriptive. Robust spread units are not accuracy,
causality, clinical significance, or proof of performance improvement.
