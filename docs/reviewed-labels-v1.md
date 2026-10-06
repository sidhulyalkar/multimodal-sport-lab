# Reviewed Labels v1

Status: M0.11 non-destructive reviewed-dataset materialization.

Human correction receipts are decisions. This stage applies those decisions to
a new label stream while keeping the original teacher labels immutable.

## Materialize

```bash
motionos materialize-reviewed-labels \
  human-correction-receipt.json \
  teacher-labels.jsonl \
  annotation-manifest.json \
  reviewed-labels.jsonl \
  reviewed-labels-receipt.json
```

The command:

1. verifies the correction receipt still binds the exact teacher-label stream;
2. revalidates source teacher labels against the annotation manifest;
3. verifies every decision against the canonical original row hash and time;
4. copies the label stream;
5. applies only explicit corrected fields;
6. sets the requested human review state;
7. attaches receipt/decision provenance to reviewed rows;
8. revalidates the complete reviewed stream;
9. writes a hash-bound materialization receipt.

## Confidence semantics

When a human replaces a field value, any model-confidence entry with the same
field name is removed from the reviewed row. MotionOS does not reinterpret a
human correction as model confidence 1.0.

Unchanged confidence values remain available for unchanged fields.

## Review states

- accepted existing or corrected -> `accepted`
- rejected -> `rejected`
- insufficient evidence -> `reviewed`

Rejected and insufficient-evidence rows remain in the artifact. Downstream
training/evaluation builders must make an explicit filtering decision rather
than silently deleting difficult cases.

## Immutability

The source `teacher-labels.jsonl` is never modified. The reviewed artifact is
a derivative with provenance back to:

- the annotation manifest;
- the original teacher-label hash;
- the human correction receipt;
- each individual decision ID.

## Scientific boundary

A reviewed label is stronger curation evidence, not automatic physical ground
truth. Evidence classes remain unchanged and runtime model qualification still
requires separate held-out evaluation and physical qualification.
