# Human Correction Receipts v1

Status: M0.10 evidence contract for explicit human review decisions.

## Why this exists

MotionOS can now move from a synchronized replay flag to an exact annotation
worklist. The missing boundary was the human decision itself.

A reviewer needs to be able to say:

- this existing label is acceptable;
- this field is wrong and should have a specific corrected value;
- this candidate should be rejected;
- there is not enough evidence to decide.

Those decisions must remain auditable and must never rewrite the original
teacher-label file in place.

## Input contract

A correction spec uses:

```json
{
  "schema_version": "motionos.human-correction-spec.v1",
  "run_id": "run-1",
  "worklist_sha256": "<sha256>",
  "reviewer": {
    "kind": "human",
    "id": "operator"
  },
  "decisions": [
    {
      "task_id": "replay-review/flag-1",
      "candidate_id": "teacher-frame/...",
      "disposition": "corrected",
      "note": "pelvis overlay was too far right",
      "corrections": {
        "derived": {
          "pelvis_offset_m": 0.012
        }
      }
    }
  ]
}
```

The reviewer ID is optional and should be a local/operator alias rather than
sensitive personal information.

Allowed dispositions are:

- `accept_existing`
- `corrected`
- `rejected`
- `insufficient_evidence`

Only `corrected` may contain field corrections.

## Evidence-class rule

A correction cannot move a value between evidence classes.

If `pelvis_offset_m` was a derived field, the corrected value remains a
derived field. If `movement_primitive` was inferred, a human correction can
provide the target value without reclassifying it as an observed sensor
measurement.

The v1 contract also forbids introducing new field names. Schema evolution
should be explicit rather than smuggled through a review patch.

## Build a receipt

```bash
motionos build-human-correction-receipt \
  human-corrections.json \
  replay-annotation-worklist.json \
  teacher-labels.jsonl \
  human-correction-receipt.json
```

The builder fails closed when:

- the correction spec does not bind the exact worklist hash;
- the worklist does not bind the exact teacher-label hash;
- a candidate no longer maps to the same teacher-label row/time;
- a candidate is reviewed more than once;
- a candidate is attached to the wrong review task;
- a non-correction disposition attempts to change fields;
- a correction tries to introduce a new field or evidence class.

## Output

Every receipt decision preserves:

- review task and candidate identity;
- disposition;
- intended future review state;
- source frame PTS and reference time;
- canonical SHA-256 of the original teacher-label row;
- before/after values for corrected fields;
- an immutable decision ID.

The receipt binds the correction spec, worklist, and teacher-label stream by
SHA-256.

## Next stage

M0.11 will consume this receipt to produce a new reviewed-label artifact. That
materialization step must remain non-destructive: raw teacher labels stay
immutable, while reviewed labels carry explicit receipt provenance.

## Scientific boundary

A human review decision improves dataset curation. It does not by itself prove
camera calibration, center of mass, force, muscle activation, diagnosis, or
runtime model accuracy.
